import unittest
from android_activity_state import activity_snapshot

class ActivitySnapshot(unittest.TestCase):
    def test_taskbar_last_does_not_hide_running_app(self):
        snapshot=activity_snapshot('topResumedActivity=ActivityRecord{app.nightfall.quest/com.godot.game.GodotAppLauncher}\n topResumedActivity=ActivityRecord{com.oculus.systemux/ActiveTaskBarActivity}')
        self.assertTrue(snapshot['nightfall_resumed'])
        self.assertIn('app.nightfall.quest/',snapshot['preferred_activity'])
        self.assertEqual(len(snapshot['resumed_activities']),2)

    def test_other_displays_do_not_prove_a_paused_app(self):
        snapshot=activity_snapshot('topResumedActivity=ActivityRecord{com.oculus.systemux/ActiveTaskBarActivity}')
        self.assertFalse(snapshot['nightfall_resumed'])
        self.assertIn('alone does not establish',snapshot['limits'])

    def test_empty_and_duplicate_records(self):
        self.assertEqual(activity_snapshot('')['preferred_activity'],'unknown')
        line='topResumedActivity=ActivityRecord{app.nightfall.quest/Launcher}'
        self.assertEqual(len(activity_snapshot(line+'\n'+line)['resumed_activities']),1)

if __name__=='__main__':unittest.main()
