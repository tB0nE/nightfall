import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'tools'))
import meteor_steam_environment as setup

ROOT=Path(__file__).resolve().parents[1]


class SteamEnvironmentTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='nf-steam-')
        self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name)
        self.root=self.base/"XR user's % library"
        (self.root/'xr-runtime').mkdir(parents=True)
        (self.root/'xr-runtime/manifest.json').write_text(json.dumps(dict(ipc_socket='nightfall-meteor/monado_comp_ipc')))
        (self.root/'test').mkdir()
        shutil.copy2(ROOT/'test/xr_runtime_registration.py',self.root/'test/xr_runtime_registration.py')
        self.config=self.base/'config'
        self.data=self.base/'data'
        self.state=self.data/'nightfall-meteor/steam'
        self.system=self.base/'system-steam.desktop'
        self.text='[Desktop Entry]\nType=Application\nName=Steam\nExec=/custom/bazzite-steam %U\nIcon=steam\n\n[Desktop Action Library]\nName=Library\nExec=/custom/bazzite-steam steam://open/games\n'
        self.system.write_text(self.text)
        monitor=patch.object(setup,'running_environment_ready',return_value=False)
        monitor.start();self.addCleanup(monitor.stop)

    def install(self):
        return setup.install(self.root,self.config,self.data,system_desktop=self.system)

    def test_environment_is_merged_without_overwriting_game_specific_choices(self):
        inherited=dict(PRESSURE_VESSEL_FILESYSTEMS_RO='/existing',
                       PRESSURE_VESSEL_FILESYSTEMS_RW='/other',
                       XR_RUNTIME_JSON='/user/explicit.json',WINEDLLOVERRIDES='winhttp=n,b')
        result=setup.environment(self.root,self.base/'runtime',inherited)
        self.assertEqual(result['XR_RUNTIME_JSON'],'/user/explicit.json')
        self.assertEqual(result['WINEDLLOVERRIDES'],'winhttp=n,b')
        self.assertEqual(result['PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES'],'1')
        self.assertEqual(result['PRESSURE_VESSEL_FILESYSTEMS_RO'],'/existing:'+str(self.root))
        self.assertEqual(setup.environment(self.root,self.base/'runtime',result),result)
        self.assertEqual(inherited['PRESSURE_VESSEL_FILESYSTEMS_RW'],'/other')
        with self.assertRaises(ValueError):
            setup.environment(Path('/bad:path'),self.base,inherited)

    def test_menu_actions_and_existing_autostart_preserve_original_commands(self):
        menu=self.data/'applications/steam.desktop';menu.parent.mkdir(parents=True)
        menu.write_text(self.text)
        autostart=self.config/'autostart/steam.desktop';autostart.parent.mkdir(parents=True)
        auto_text=self.text.replace('%U','-silent %U')
        autostart.write_text(auto_text)
        original_options=self.base/'localconfig.vdf';original_options.write_text('untouched Steam settings')
        result=self.install()
        self.assertTrue(result['configured'])
        self.assertTrue(result['steam_restart_required'])
        wrapped=menu.read_text()
        self.assertIn(' -- /custom/bazzite-steam %U',wrapped)
        self.assertIn(' -- /custom/bazzite-steam steam://open/games',wrapped)
        self.assertIn('Icon=steam',wrapped)
        self.assertIn('-silent %U',autostart.read_text())
        self.assertFalse(self.install()['changed'])
        self.assertTrue(setup.remove(self.state)['removed'])
        self.assertEqual(menu.read_text(),self.text)
        self.assertEqual(autostart.read_text(),auto_text)
        self.assertEqual(original_options.read_text(),'untouched Steam settings')

    def test_no_existing_autostart_is_created(self):
        self.install()
        self.assertFalse((self.config/'autostart/steam.desktop').exists())
        setup.remove(self.state)
        self.assertFalse((self.data/'applications/steam.desktop').exists())
        self.assertEqual(self.system.read_text(),self.text)

    def test_external_launcher_edit_is_retained(self):
        self.install()
        menu=self.data/'applications/steam.desktop'
        menu.write_text('[Desktop Entry]\nExec=/user/new-command\n')
        self.assertFalse(setup.status(self.state)['configured'])
        result=setup.remove(self.state)
        self.assertFalse(result['removed'])
        self.assertEqual(menu.read_text(),'[Desktop Entry]\nExec=/user/new-command\n')
        self.assertTrue(list(menu.parent.glob('*.meteor-backup-*'))==[])
        # No original per-user file existed; the system launcher is untouched.
        self.assertEqual(self.system.read_text(),self.text)

    def test_partial_failure_rolls_back_and_next_install_recovers(self):
        autostart=self.config/'autostart/steam.desktop';autostart.parent.mkdir(parents=True)
        autostart.write_text(self.text)
        real=setup.registration_module
        def broken(state):
            module=real(state)
            acquire=module.acquire
            def fail(destination,target,journal):
                if destination==autostart:
                    raise OSError('simulated failure')
                acquire(destination,target,journal)
            module.acquire=fail
            return module
        with patch.object(setup,'registration_module',broken):
            with self.assertRaises(OSError):
                self.install()
        self.assertFalse((self.data/'applications/steam.desktop').exists())
        self.assertEqual(autostart.read_text(),self.text)
        self.assertTrue(self.install()['configured'])
        setup.remove(self.state)

    def test_flatpak_is_not_silently_treated_as_native(self):
        self.system.write_text('[Desktop Entry]\nExec=flatpak run com.valvesoftware.Steam %U\n')
        with self.assertRaisesRegex(ValueError,'Flatpak'):
            self.install()
        self.assertFalse((self.data/'applications/steam.desktop').exists())

    def test_standalone_helper_merges_at_runtime_and_survives_runtime_removal(self):
        self.install()
        helper=self.state/'environment.py'
        script='import json,os,sys; print(json.dumps(dict(args=sys.argv[1:],imported=os.environ.get("PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES"),ro=os.environ.get("PRESSURE_VESSEL_FILESYSTEMS_RO"))))'
        command=[sys.executable,str(helper),'run','--root',str(self.root),'--',sys.executable,'-c',script,'argument with spaces']
        env=dict(os.environ,XDG_RUNTIME_DIR=str(self.base/'runtime'))
        env.pop('PRESSURE_VESSEL_IMPORT_OPENXR_1_RUNTIMES',None)
        result=subprocess.run(command,env=env,capture_output=True,text=True,check=True,timeout=3)
        value=json.loads(result.stdout)
        self.assertEqual(value['args'],['argument with spaces'])
        self.assertEqual(value['imported'],'1')
        shutil.rmtree(self.root)
        result=subprocess.run(command,env=env,capture_output=True,text=True,check=True,timeout=3)
        self.assertIsNone(json.loads(result.stdout)['imported'])
        self.assertTrue(setup.remove(self.state)['removed'])

    def test_python310_reads_the_setup_generated_xr_boolean_table(self):
        import builtins
        original=builtins.__import__
        def without_tomllib(name,*args,**kwargs):
            if name=='tomllib':raise ImportError('Python 3.10')
            return original(name,*args,**kwargs)
        with patch('builtins.__import__',side_effect=without_tomllib):
            self.assertEqual(setup.xr_preferences('# user settings\n[xr]\nenabled=true # yes\nautomatic_launch=true\n[other]\nenabled=false\n'),
                             dict(enabled=True,automatic_launch=True))
            self.assertEqual(setup.xr_preferences('xr={enabled=true,automatic_launch=true}'),{})

    def test_automatic_library_readiness_requires_config_and_updated_steam_session(self):
        self.install()
        path=self.config/'nightfall-meteor/meteor.toml'
        path.parent.mkdir(parents=True)
        path.write_text('[xr]\nenabled=true\nautomatic_launch=true\n')
        with patch.dict(os.environ,dict(XDG_CONFIG_HOME=str(self.config),XDG_DATA_HOME=str(self.data))):
            self.assertFalse(setup.automatic_launch_ready(self.root))
            with patch.object(setup,'running_environment_ready',return_value=True):
                self.assertTrue(setup.automatic_launch_ready(self.root))
                self.assertFalse(setup.automatic_launch_ready(self.base/'other-runtime'))
                path.write_text('[xr]\nenabled=true\nautomatic_launch=false\n')
                self.assertFalse(setup.automatic_launch_ready(self.root))

    def test_desktop_launch_uses_real_gio_argument_and_field_code_rules(self):
        try:
            import gi
            gi.require_version('GioUnix','2.0')
            from gi.repository import Gio,GioUnix
        except (ImportError,ValueError):
            self.skipTest('GIO desktop parser unavailable')
        special=self.base/'XR % $dollar `tick` \"quoted\"'
        self.root.rename(special); self.root=special
        result_path=self.base/'result.json'
        receiver=self.base/'receiver.py'
        receiver.write_text('import json,os,sys; from pathlib import Path; Path(sys.argv[1]).write_text(json.dumps(dict(args=sys.argv[2:],ro=os.environ.get("PRESSURE_VESSEL_FILESYSTEMS_RO"))))')
        self.system.write_text('[Desktop Entry]\nType=Application\nName=Fixture Steam\nExec='+setup.desktop_quote(sys.executable)+' '+setup.desktop_quote(receiver)+' '+setup.desktop_quote(result_path)+' %U\n')
        self.install()
        app=GioUnix.DesktopAppInfo.new_from_filename(str(self.data/'applications/steam.desktop'))
        self.assertIsNotNone(app)
        context=Gio.AppLaunchContext()
        context.setenv('XDG_RUNTIME_DIR',str(self.base/'runtime'))
        url='steam://fixture/one?x=1&y=2'
        self.assertTrue(app.launch_uris([url],context))
        deadline=time.monotonic()+3
        while not result_path.exists() and time.monotonic()<deadline:
            time.sleep(0.01)
        self.assertTrue(result_path.exists())
        value=json.loads(result_path.read_text())
        self.assertEqual(value['args'],[url])
        self.assertIn(str(self.root),value['ro'])
        setup.remove(self.state)


if __name__=='__main__':
    unittest.main()
