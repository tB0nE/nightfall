import unittest
from unittest.mock import patch
from xr_audio_environment import host_audio_environment


class AudioEnvironmentTests(unittest.TestCase):
    def test_private_xr_directory_does_not_redirect_audio(self):
        host={"XDG_RUNTIME_DIR":"/run/user/1000","UNRELATED_SECRET":"do-not-copy"}
        with patch("xr_audio_environment.Path.is_socket",return_value=True):
            endpoints=host_audio_environment(host)
        child={"XDG_RUNTIME_DIR":"/tmp/private-monado","XR_RUNTIME_JSON":"/private/runtime.json",**endpoints}
        self.assertEqual(child["XDG_RUNTIME_DIR"],"/tmp/private-monado")
        self.assertEqual(child["XR_RUNTIME_JSON"],"/private/runtime.json")
        self.assertEqual(child["PULSE_SERVER"],"unix:/run/user/1000/pulse/native")
        self.assertEqual(child["PIPEWIRE_RUNTIME_DIR"],"/run/user/1000")
        self.assertNotIn("UNRELATED_SECRET",child)

    def test_explicit_endpoints_win_and_missing_sockets_are_not_invented(self):
        explicit={"XDG_RUNTIME_DIR":"/run/user/1000","PULSE_SERVER":"tcp:custom-server",
                  "PULSE_RUNTIME_PATH":"/custom/pulse","PIPEWIRE_RUNTIME_DIR":"/custom/pipewire"}
        with patch("xr_audio_environment.Path.is_socket",return_value=True):
            result=host_audio_environment(explicit)
        self.assertEqual(result["PULSE_SERVER"],"tcp:custom-server")
        self.assertEqual(result["PIPEWIRE_RUNTIME_DIR"],"/custom/pipewire")
        self.assertEqual(result["PULSE_RUNTIME_PATH"],"/custom/pulse")
        with patch("xr_audio_environment.Path.is_socket",return_value=True):
            custom=host_audio_environment({"XDG_RUNTIME_DIR":"/run/user/1000","PULSE_RUNTIME_PATH":"/custom/pulse"})
        self.assertEqual(custom["PULSE_SERVER"],"unix:/custom/pulse/native")
        with patch("xr_audio_environment.Path.is_socket",return_value=False):
            self.assertEqual(host_audio_environment({"XDG_RUNTIME_DIR":"/missing"}),{})
        self.assertEqual(host_audio_environment({}),{})
