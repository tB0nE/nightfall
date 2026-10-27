"""Validate source hashes and offline Cargo resolution from the source companion."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile


def run(archive, destination):
    destination.mkdir(parents=True)
    with tarfile.open(archive) as source:
        source.extractall(destination, filter='data')
    info=json.loads((destination/'SOURCE_MANIFEST.json').read_text())
    for name,expected in info['source_sha256'].items():
        relative=Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Source manifest contains an invalid path')
        path=destination/'Nightfall'/relative
        assert hashlib.sha256(path.read_bytes()).hexdigest()==expected,name
        assert '.env' not in path.name and path.suffix not in ('.keystore','.jks','.pem','.p12')
    env=dict(os.environ,CARGO_HOME=str(destination/'cargo-home'))
    for project,label in [('Nightfall/meteor','meteor'),('upstream/xrizer','xrizer')]:
        with (destination/(label+'-metadata.json')).open('w') as output:
            subprocess.run(['cargo','--config','.cargo/vendor-config.toml','metadata',
                            '--offline','--locked','--format-version','1'],cwd=destination/project,
                           env=env,stdout=output,check=True)
    report={'source_files_verified':len(info['source_sha256']),
            'cargo_offline':['meteor','xrizer'],'archive_bytes':archive.stat().st_size}
    (destination/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive',type=Path)
    parser.add_argument('--work-dir',type=Path,required=True)
    args=parser.parse_args()
    run(args.archive.resolve(),args.work_dir.resolve())
