#!/usr/bin/env python3
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(TOOLS))
SPEC = importlib.util.spec_from_file_location('steam_options', TOOLS / 'meteor_steam_options.py')
options = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(options)

ROOT = '/home/u/.local/share/nightfall-meteor/xr'
LINE = options.wrapper_line(ROOT)
CORE = LINE[:-len(options.COMMAND)]
VENV = ('/repo/.build-cache/model-tester-venv/bin/python /repo/tools/meteor_xr.py '
        'steam-run --app-id 2571030 --wait 120 -- %command%')
CONFIG = '''"UserLocalConfigStore"
{
\t"friends"
\t{
\t\t"LaunchOptions"\t\t"not an app"
\t}
\t"Software"
\t{
\t\t"Valve"
\t\t{
\t\t\t"Steam"
\t\t\t{
\t\t\t\t"cdn"\t\t"{not a brace}"
\t\t\t\t"apps"
\t\t\t\t{
\t\t\t\t\t"100"
\t\t\t\t\t{
\t\t\t\t\t\t"LastPlayed"\t\t"1"
\t\t\t\t\t}
\t\t\t\t\t"200"
\t\t\t\t\t{
\t\t\t\t\t\t"LaunchOptions"\t\t"WINEDLLOVERRIDES=\\"UE4SS=n,b\\" %command% -vrmode openvr"
\t\t\t\t\t\t"cloud"
\t\t\t\t\t\t{
\t\t\t\t\t\t\t"last_sync_state"\t\t"synchronized"
\t\t\t\t\t\t}
\t\t\t\t\t}
\t\t\t\t\t"999"
\t\t\t\t\t{
\t\t\t\t\t\t"LaunchOptions"\t\t"keep %command%"
\t\t\t\t\t}
\t\t\t\t}
\t\t\t}
\t\t}
\t}
}
'''


def launch_options(text, app_id):
    apps = options.library.vdf(text)['UserLocalConfigStore']['Software']['Valve']['Steam']['apps']
    return apps.get(app_id, {}).get('LaunchOptions', '')


class Options(unittest.TestCase):
    def test_empty_options_become_the_wrapper(self):
        self.assertEqual(options.with_wrapper('', ROOT), LINE)

    def test_user_variables_stay_before_the_wrapper(self):
        got = options.with_wrapper('WINE_CPU_TOPOLOGY=8:0,1 %command% -vrmode openvr', ROOT)
        self.assertEqual(got, f'WINE_CPU_TOPOLOGY=8:0,1 {CORE}%command% -vrmode openvr')

    def test_arguments_without_command_go_after_the_game(self):
        self.assertEqual(options.with_wrapper('-vrmode openvr', ROOT), f'{LINE} -vrmode openvr')

    def test_adding_twice_changes_nothing(self):
        once = options.with_wrapper('A=1 %command%', ROOT)
        self.assertEqual(options.with_wrapper(once, ROOT), once)

    def test_an_old_wrapper_is_replaced(self):
        self.assertEqual(options.with_wrapper(f'A=1 {VENV}', ROOT), f'A=1 {LINE}')

    def test_removing_keeps_only_what_the_user_wrote(self):
        self.assertEqual(options.without_wrapper(LINE), '')
        self.assertEqual(options.without_wrapper(f'A=1 {CORE}%command% -x'), 'A=1 %command% -x')
        self.assertEqual(options.without_wrapper(f'A=1 {VENV}'), 'A=1 %command%')
        self.assertEqual(options.without_wrapper('A=1 %command%'), 'A=1 %command%')

    def test_a_doubled_command_is_repaired(self):
        self.assertEqual(options.without_wrapper(f'A=1 {CORE}%command% %command% -x'), 'A=1 %command% -x')

    def test_the_path_is_quoted_for_the_shell(self):
        self.assertIn("'/home/Ty'\"'\"'s/tools/meteor_xr.py'", options.wrapper_line("/home/Ty's"))


class Config(unittest.TestCase):
    def add(self, value):
        return options.with_wrapper(value, ROOT)

    def test_edits_only_the_chosen_apps_options(self):
        text, count = options.edit_options(CONFIG, ['100', '200'], self.add)
        self.assertEqual(count, 2)
        self.assertEqual(launch_options(text, '100'), LINE)
        self.assertEqual(launch_options(text, '200'), f'WINEDLLOVERRIDES="UE4SS=n,b" {CORE}%command% -vrmode openvr')
        self.assertEqual(launch_options(text, '999'), 'keep %command%')
        self.assertIn('"LaunchOptions"\t\t"not an app"', text)
        self.assertIn('"cdn"\t\t"{not a brace}"', text)
        self.assertIn('"last_sync_state"', text)

    def test_an_app_steam_has_no_entry_for_gets_one(self):
        text, count = options.edit_options(CONFIG, ['300'], self.add)
        self.assertEqual(count, 1)
        self.assertEqual(launch_options(text, '300'), LINE)

    def test_add_then_remove_restores_the_user_options(self):
        added, _ = options.edit_options(CONFIG, ['200'], self.add)
        removed, _ = options.edit_options(added, ['200'], options.without_wrapper)
        self.assertEqual(removed, CONFIG)

    def test_a_second_add_writes_nothing(self):
        added, _ = options.edit_options(CONFIG, ['100', '200', '300'], self.add)
        again, count = options.edit_options(added, ['100', '200', '300'], self.add)
        self.assertEqual((again, count), (added, 0))

    def test_removing_from_an_app_without_options_adds_nothing(self):
        text, count = options.edit_options(CONFIG, ['100', '300'], options.without_wrapper)
        self.assertEqual((text, count), (CONFIG, 0))

    def test_a_file_without_apps_is_refused(self):
        with self.assertRaises(ValueError):
            options.edit_options('"UserLocalConfigStore"\n{\n}\n', ['100'], self.add)

    def test_write_keeps_the_first_backup_and_the_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'localconfig.vdf'
            path.write_text(CONFIG)
            path.chmod(0o600)
            options.write_config(path, CONFIG + '\n')
            options.write_config(path, CONFIG + '\n\n')
            self.assertEqual((Path(directory) / 'localconfig.vdf.before-meteor').read_text(), CONFIG)
            self.assertEqual(path.read_text(), CONFIG + '\n\n')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(sorted(p.name for p in Path(directory).iterdir()),
                             ['localconfig.vdf', 'localconfig.vdf.before-meteor'])


class Run(unittest.TestCase):
    """The steps around the edit, with nothing touching the real Steam."""

    def setUp(self):
        self.steps = []
        self.saved = {name: getattr(options, name) for name in
                      ('games', 'game_running', 'steam_pid', 'close_steam', 'open_steam', 'apply', 'status')}
        options.games = lambda: [{'id': '100', 'name': 'A', 'ready': False}]
        options.game_running = lambda: False
        options.steam_pid = lambda: 42
        options.close_steam = lambda pid: self.steps.append(('close', pid))
        options.open_steam = lambda: self.steps.append(('open',))
        options.status = lambda: {'total': 1, 'ready': 1}

        def apply(change, ids):
            self.steps.append(('edit', ids))
            return 1
        options.apply = apply

    def tearDown(self):
        for name, value in self.saved.items():
            setattr(options, name, value)

    def test_steam_closes_before_the_edit_and_reopens_after(self):
        self.assertEqual(options.run('add')['changed'], 1)
        self.assertEqual(self.steps, [('close', 42), ('edit', ['100']), ('open',)])

    def test_steam_stays_closed_if_it_was_not_running(self):
        options.steam_pid = lambda: None
        options.run('add')
        self.assertEqual(self.steps, [('edit', ['100'])])

    def test_steam_reopens_even_if_the_edit_fails(self):
        def fail(change, ids):
            raise ValueError('bad file')
        options.apply = fail
        with self.assertRaises(ValueError):
            options.run('add')
        self.assertEqual(self.steps, [('close', 42), ('open',)])

    def test_a_running_game_stops_it_before_steam_is_touched(self):
        options.game_running = lambda: True
        self.assertIn('error', options.run('add'))
        self.assertEqual(self.steps, [])

    def test_no_vr_games_stops_it_before_steam_is_touched(self):
        options.games = lambda: []
        self.assertIn('error', options.run('add'))
        self.assertEqual(self.steps, [])


if __name__ == '__main__':
    unittest.main()
