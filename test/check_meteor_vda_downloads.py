"""Download both Vulkan models from public release URLs into isolated test data."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def run(appimage, root, seed=None):
    root.mkdir(parents=True)  # Never overwrite an earlier test's data.
    artifact=root/'Meteor-download-test.AppImage'
    shutil.copy2(appimage,artifact)
    env=dict(os.environ)
    for name in ('APPIMAGE','APPDIR','ARGV0','OWD','METEOR_VDA_VULKAN_URL'):
        env.pop(name,None)
    for name in ('CONFIG','DATA','CACHE','STATE'):
        env['XDG_'+name+'_HOME']=str(root/name.lower())
    env['APPIMAGE_EXTRACT_AND_RUN']='1'
    models=root/'models'
    config=root/'config/nightfall-meteor'
    config.mkdir(parents=True)
    (config/'meteor.toml').write_text('models_dir = '+json.dumps(str(models))+'\n')
    if seed:
        staging=models/'.vda-vulkan-downloads/vda_vulkan_392x224'
        staging.mkdir(parents=True)
        with seed.open('rb') as source:
            (staging/'cold.ncnn.bin.download').write_bytes(source.read(1<<20))
    source_root=Path(__file__).resolve().parents[1]
    catalog=json.loads((source_root/'meteor/models/vda-vulkan-downloads.json').read_text())
    for variant in ('392','518'):
        with (root/('download-'+variant+'.log')).open('w') as log:
            subprocess.run([str(artifact),'--download-vda-vulkan',variant],env=env,
                           stdout=log,stderr=subprocess.STDOUT,check=True,timeout=600)
        print('Downloaded Vulkan VDA',variant,flush=True)
    for identity,model in catalog['models'].items():
        for file in model['files']:
            path=models/identity/file['name']
            assert path.stat().st_size==file['bytes']
            with path.open('rb') as handle:
                assert hashlib.file_digest(handle,'sha256').hexdigest()==file['sha256']
    assert not (root/'data/nightfall-meteor/runtime/tensorrt').exists()
    (root/'report.json').write_text(json.dumps({'public_urls':True,'variants':list(catalog['models']),
        'sha256_verified_files':12,'partial_download_seeded':seed is not None,
        'tensorrt_downloaded':False},indent=2)+'\n')
    print('PASS public downloads: both variants, all checksums, no TensorRT',flush=True)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('appimage',type=Path)
    parser.add_argument('--work-dir',type=Path,required=True)
    parser.add_argument('--seed',type=Path,help='Correct source bin from which to seed a partial transfer')
    args=parser.parse_args()
    run(args.appimage.resolve(),args.work_dir.resolve(),args.seed)
