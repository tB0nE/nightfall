import importlib.util,json,tempfile,unittest,struct
from pathlib import Path
from unittest.mock import patch
SPEC=importlib.util.spec_from_file_location('vr_library',Path(__file__).resolve().parents[1]/'tools/meteor_vr_library.py')
LIB=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(LIB)
class LibraryTests(unittest.TestCase):
    def test_nonsteam_vr_shortcuts_and_64_bit_launch_id(self):
        with tempfile.TemporaryDirectory() as temporary:
            steam=Path(temporary);config=steam/'userdata/1/config';config.mkdir(parents=True)
            (steam/'config').mkdir()
            (steam/'config/steamapps.vrmanifest').write_text(json.dumps({'applications':[{'app_key':'steam.app.2944203442'}]}))
            def record(index,app_id,name,options='',vr=0):
                return b'\0'+index.encode()+b'\0'+b'\x02appid\0'+struct.pack('<I',app_id)+b'\x01AppName\0'+name.encode()+b'\0'+b'\x01LaunchOptions\0'+options.encode()+b'\0'+b'\x02IsOpenVR\0'+struct.pack('<I',vr)+b'\x08'
            data=b'\0shortcuts\0'+record('0',2944203442,'BraindanceVR','python meteor_xr.py steam-run --app-id 2944203442 -- %command%')+record('1',123,'Flat shortcut')+record('2',456,'Flagged VR',vr=1)+b'\x08\x08'
            path=config/'shortcuts.vdf';path.write_bytes(data)
            parsed,spans=LIB.shortcut_records(path)
            start,end=spans[('shortcuts','0','LaunchOptions')]
            self.assertEqual(data[start:end-1].decode(),parsed['shortcuts']['0']['LaunchOptions'])
            with patch.object(LIB,'steam_roots',return_value=[steam]),patch.object(LIB,'CACHE',steam/'cache'),patch.object(LIB.subprocess,'Popen') as launch:
                value=LIB.action('list');self.assertEqual(value['total'],2)
                app=next(a for a in value['apps'] if a['name']=='BraindanceVR')
                self.assertTrue(app['ready']);self.assertNotIn('_shortcut',app)
                LIB.action('launch',app['key'])
                self.assertEqual(launch.call_args.args[0][1:],['steam://rungameid/'+str((2944203442<<32)|0x02000000)])
    def test_truncated_shortcuts_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'shortcuts.vdf';path.write_bytes(b'\0shortcuts\0\x01name\0unterminated')
            with self.assertRaises(ValueError):LIB.shortcut_records(path)
    def test_installed_vr_discovery_ready_status_paging_and_no_private_fields(self):
        with tempfile.TemporaryDirectory() as temporary:
            steam=Path(temporary);(steam/'config').mkdir();(steam/'steamapps/common/Test Game').mkdir(parents=True)
            (steam/'steamapps/common/Flat Game').mkdir()
            (steam/'config/steamapps.vrmanifest').write_text(json.dumps({'applications':[{'app_key':'steam.app.123','strings':{'en_us':{'name':'Test Game'}}}]}))
            for app,name in [('123','Test Game'),('456','Flat Game')]:
                (steam/f'steamapps/appmanifest_{app}.acf').write_text(f'"AppState" {{"appid" "{app}" "name" "{name}" "installdir" "{name}" "StateFlags" "4"}}')
            local=steam/'userdata/1/config';local.mkdir(parents=True)
            (local/'localconfig.vdf').write_text('"UserLocalConfigStore" {"Software" {"Valve" {"Steam" {"apps" {"123" {"LaunchOptions" "python /local/meteor_xr.py steam-run --app-id 123 -- %command%"}}}}}}')
            with patch.object(LIB,'steam_roots',return_value=[steam]):
                value=LIB.action('list')
                self.assertEqual(value['total'],1);self.assertTrue(value['apps'][0]['ready'])
                self.assertEqual(value['apps'][0]['key'],'steam:123')
                self.assertNotIn('_art',value['apps'][0]);self.assertNotIn('LaunchOptions',json.dumps(value))
                self.assertEqual(LIB.action('list',offset=4)['apps'],[])
                with self.assertRaises(ValueError):LIB.action('launch','steam:456')
    def test_thumbnails_are_square_and_control_frame_bounded(self):
        from PIL import Image
        import base64,io
        with tempfile.TemporaryDirectory() as temporary:
            path=Path(temporary)/'cover.png';Image.new('RGB',(600,900),'blue').save(path)
            result=LIB.thumbnail({'_art':[str(path)]})
            self.assertLessEqual(len(result),2400)
            image=Image.open(io.BytesIO(base64.b64decode(result)))
            self.assertEqual(image.width,image.height);self.assertLessEqual(image.width,128)
    def test_unconfigured_game_is_not_launched(self):
        with patch.object(LIB,'discover',return_value=[{'key':'steam:1','vr':True,'ready':False}]):
            with self.assertRaisesRegex(ValueError,'launch options'):LIB.action('launch','steam:1')
if __name__=='__main__':unittest.main()
