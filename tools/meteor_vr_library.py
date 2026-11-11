#!/usr/bin/env python3
"""Host-local installed VR library. Only IDs cross the authenticated XR channel."""
import argparse,base64,io,json,os,re,shutil,struct,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).absolute().parents[1]
CACHE=ROOT/'.build-cache/meteor-xr'
MAX_FILE=32*1024*1024

def read(path,maximum=MAX_FILE):
    path=Path(path)
    if path.stat().st_size>maximum:raise ValueError('Metadata too large')
    return path.read_text(errors='replace')

def vdf(text):
    tokens=re.findall(r'"((?:\\.|[^"\\])*)"|([{}])',re.sub(r'//[^\n]*','',text))
    values=[quoted.replace('\\\\','\\').replace('\\"','"') if not brace else brace for quoted,brace in tokens]
    position=0
    def block(depth=0):
        nonlocal position
        if depth>32:raise ValueError('VDF nesting limit')
        result={}
        while position<len(values):
            key=values[position];position+=1
            if key=='}':return result
            if position>=len(values):break
            value=values[position];position+=1
            result[key]=block(depth+1) if value=='{' else value
        return result
    return block()

APPINFO_VR=('openvrsupport','openxrsupport','onlyvrsupport')

def appinfo_vr(path,wanted):
    """App ids among `wanted` that Steam's appinfo.vdf marks as VR (appinfo/common).

    A clean Linux install has no steamapps.vrmanifest: Steam didn't write it with
    SteamVR installed and run (Bazzite, November 2026), and Meteor's runtime doesn't
    need SteamVR at all. appinfo.vdf is Steam's own app metadata and is always there.
    Only the wanted entries are decoded; the rest are skipped by their size.
    """
    found=set()
    with open(path,'rb') as f:
        magic,_=struct.unpack('<II',f.read(8))
        if magic not in (0x07564428,0x07564429):raise ValueError('Unsupported appinfo.vdf version')
        strings=None
        if magic==0x07564429:
            offset,=struct.unpack('<q',f.read(8));start=f.tell();f.seek(offset)
            count,=struct.unpack('<I',f.read(4));strings=f.read().split(b'\0')[:count];f.seek(start)
        while True:
            head=f.read(8)
            if len(head)<8:break
            app_id,size=struct.unpack('<II',head)
            if app_id==0:break
            if str(app_id) not in wanted:f.seek(size,1);continue
            # infostate, last updated, PICS token, SHA-1, change number, binary SHA-1.
            data=f.read(size)[60:];position=0
            def key():
                nonlocal position
                if strings is not None:
                    index,=struct.unpack_from('<I',data,position);position+=4
                    return strings[index].decode('utf8','replace').lower()
                end=data.index(0,position);value=data[position:end].decode('utf8','replace').lower();position=end+1
                return value
            def block(path,depth=0):
                nonlocal position
                if depth>32:raise ValueError('VDF nesting limit')
                while position<len(data):
                    kind=data[position];position+=1
                    if kind in (8,11):return
                    name=key()
                    if kind==0:block(path+(name,),depth+1);continue
                    if kind==1:
                        end=data.index(0,position);value=data[position:end];position=end+1
                        flagged=value.strip() not in (b'',b'0')
                    elif kind in (2,3,4,6):flagged=data[position:position+4]!=bytes(4);position+=4
                    elif kind in (7,10):flagged=data[position:position+8]!=bytes(8);position+=8
                    else:raise ValueError('Unsupported appinfo field type')
                    if path==('appinfo','common') and name in APPINFO_VR and flagged:found.add(str(app_id))
            block(())
    return found

def steam_roots():
    home=Path.home()
    paths=[home/'.local/share/Steam',home/'.steam/steam',home/'.var/app/com.valvesoftware.Steam/.local/share/Steam']
    return list(dict.fromkeys(p.resolve() for p in paths if p.is_dir()))

def shortcut_records(path):
    """Read Steam's binary VDF, retaining value spans for surgical option edits."""
    data=Path(path).read_bytes()
    if len(data)>MAX_FILE:raise ValueError('Metadata too large')
    position=0; spans={}
    def string():
        nonlocal position
        end=data.index(0,position);value=data[position:end].decode('utf8',errors='strict');position=end+1
        return value
    def block(parents=(),depth=0):
        nonlocal position
        if depth>32:raise ValueError('VDF nesting limit')
        result={}
        while position<len(data):
            kind=data[position];position+=1
            if kind==8:return result
            key=string();start=position;field=parents+(key,)
            if kind==0:value=block(field,depth+1)
            elif kind==1:value=string();spans[field]=(start,position)
            elif kind in (2,7):
                size=4 if kind==2 else 8
                value=struct.unpack_from('<I' if kind==2 else '<Q',data,position)[0];position+=size
            else:raise ValueError('Unsupported shortcut field type')
            result[key]=value
        raise ValueError('Truncated shortcut metadata')
    return block(),spans

def wrapper_ready(options,app_id):
    return 'meteor_xr.py' in options and 'steam-run' in options and bool(re.search(r'--app-id\s+(?:'+re.escape(app_id)+r'|auto)(?:\s|$)',options))

def discover():
    result={}
    for steam in steam_roots():
        vr={}
        try:
            for app in json.loads(read(steam/'config/steamapps.vrmanifest')).get('applications',[]):
                match=re.fullmatch(r'steam.app.([0-9]+)',app.get('app_key',''))
                if match:vr[match[1]]=app
        except (OSError,ValueError):pass
        libraries=[steam]
        try:
            for item in vdf(read(steam/'steamapps/libraryfolders.vdf')).get('libraryfolders',{}).values():
                if isinstance(item,dict) and isinstance(item.get('path'),str):libraries.append(Path(item['path']))
        except (OSError,ValueError):pass
        # Read only launch-option fields; never expose account configuration.
        ready=set()
        for local in (steam/'userdata').glob('*/config/localconfig.vdf'):
            try:
                apps=vdf(read(local)).get('UserLocalConfigStore',{}).get('Software',{}).get('Valve',{}).get('Steam',{}).get('apps',{})
                for app_id,entry in apps.items():
                    options=entry.get('LaunchOptions','') if isinstance(entry,dict) else ''
                    if wrapper_ready(options,app_id):ready.add(app_id)
            except (OSError,ValueError,AttributeError):pass
        installed=[]
        for library in dict.fromkeys(libraries):
            for manifest in (library/'steamapps').glob('appmanifest_*.acf'):
                try:installed.append((library,vdf(read(manifest)).get('AppState',{})))
                except (OSError,ValueError,AttributeError):continue
        try:flagged=appinfo_vr(steam/'appcache/appinfo.vdf',{str(app.get('appid','')) for _,app in installed})
        except (OSError,ValueError,IndexError,struct.error):flagged=set()
        for library,app in installed:
            try:
                app_id=app.get('appid','')
                if (app_id not in vr and app_id not in flagged) or not (library/'steamapps/common'/app.get('installdir','')).is_dir():continue
                if not int(app.get('StateFlags','0'))&4:continue
                art=[]
                for pattern in (f'{app_id}/*library_600x900*',f'{app_id}/*library*',f'{app_id}_library_600x900*',f'{app_id}_header*'):
                    art.extend((steam/'appcache/librarycache').glob(pattern))
                image=vr.get(app_id,{}).get('image_path','')
                if image and Path(image).is_file():art.append(Path(image))
                key='steam:'+app_id
                result[key]={'key':key,'source':'Steam','name':str(app.get('name','Steam '+app_id)).encode('utf8','replace')[:96].decode('utf8','ignore'),'vr':True,'ready':app_id in ready,'_art':[str(p) for p in art if p.is_file()]}
            except (OSError,ValueError,AttributeError):continue
        for shortcuts in (steam/'userdata').glob('*/config/shortcuts.vdf'):
            try:
                records,_=shortcut_records(shortcuts)
                for entry in records.get('shortcuts',{}).values():
                    entry={k.lower():v for k,v in entry.items()}
                    app_id=str(entry.get('appid',0))
                    # Steam's VR manifest is authoritative; also honor its shortcut VR flag.
                    if app_id not in vr and not entry.get('isopenvr',0):continue
                    if not 0<int(app_id)<=0xffffffff:continue
                    key='steam:'+app_id
                    if key in result:continue
                    art=list((shortcuts.parent/'grid').glob(app_id+'*'))
                    image=vr.get(app_id,{}).get('image_path','')
                    if image and Path(image).is_file():art.append(Path(image))
                    result[key]={'key':key,'source':'Steam','name':str(entry.get('appname','Steam shortcut')).encode('utf8','replace')[:96].decode('utf8','ignore'),'vr':True,'ready':wrapper_ready(entry.get('launchoptions',''),app_id),'_art':[str(p) for p in art if p.is_file()],'_shortcut':True}
            except (OSError,ValueError,AttributeError,struct.error):continue
    return sorted(result.values(),key=lambda a:(a['name'].casefold(),a['key']))[:1000]

def thumbnail(app):
    try:from PIL import Image,ImageOps
    except ImportError:return ''
    for candidate in app['_art']:
        try:
            if Path(candidate).stat().st_size>16*1024*1024:continue
            with Image.open(candidate) as original:
                for size in (128,96,64):
                    image=ImageOps.fit(original.convert('RGB'),(size,size))
                    stream=io.BytesIO();image.save(stream,format='WEBP',quality=55)
                    if stream.tell()<=1800:return base64.b64encode(stream.getvalue()).decode('ascii')
        except (OSError,ValueError,Image.DecompressionBombError):continue
    return ''

def action(command,key='',offset=0):
    apps=discover(); by_key={a['key']:a for a in apps}
    if command=='list':
        visible=apps
        page=[{k:v for k,v in a.items() if not k.startswith('_')} for a in visible[offset:offset+4]]
        return {'action':'list','apps':page,'offset':offset,'total':len(visible)}
    if command=='art':return {'action':'art','key':key,'image':thumbnail(by_key[key]) if key in by_key else ''}
    if command=='launch':
        app=by_key.get(key)
        if not app or not app['vr']:raise ValueError('Choose an installed VR app')
        if not app['ready']:raise ValueError('Add Meteor launch options in this game’s Steam properties first')
        app_id=key.split(':')[1]
        CACHE.mkdir(parents=True,exist_ok=True)
        steam=shutil.which('steam') or '/usr/bin/steam'
        # Non-Steam shortcuts use a 64-bit game ID, not the store app launch API.
        args=[steam,'steam://rungameid/'+str((int(app_id)<<32)|0x02000000)] if app.get('_shortcut') else [steam,'-applaunch',app_id]
        with (CACHE/'library-launch.log').open('ab') as log:
            subprocess.Popen(args,stdin=subprocess.DEVNULL,stdout=log,stderr=log,start_new_session=True)
        return {'action':'launch','key':key,'message':'Starting '+app['name']}
    raise ValueError('Unknown library action')

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['list','art','launch']);parser.add_argument('--key',default='');parser.add_argument('--offset',type=int,default=0);args=parser.parse_args()
    try:print(json.dumps(action(args.action,args.key,max(0,args.offset)),ensure_ascii=True))
    except Exception as error:print(json.dumps({'action':args.action,'error':str(error)[:180]}))
