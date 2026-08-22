import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "configure.py"
SPEC = importlib.util.spec_from_file_location("agent_monitor_configure", SCRIPT)
configure = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(configure)


class ConfigureTests(unittest.TestCase):
    def test_install_and_uninstall_preserve_unrelated_codex_and_claude_configuration(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            root = Path(temporary_directory)
            codex = root / ".codex"
            claude = root / ".claude"
            codex.mkdir()
            claude.mkdir()
            helper = root / "Agent Monitor.app" / "agent-monitor-helper"

            unrelated = {"matcher": "tool", "hooks": [{"type": "command", "command": "keep-me"}]}
            old_monitor = {"matcher": "", "hooks": [{"type": "command", "command": '"/old/agent-monitor-helper" codex-hook'}]}
            hooks_path = codex / "hooks.json"
            hooks_path.write_text(json.dumps({
                "description": configure.DESCRIPTION,
                "hooks": {"Stop": [unrelated, old_monitor], "PermissionRequest": [old_monitor]},
            }))
            claude_path = claude / "settings.json"
            claude_path.write_text(json.dumps({"hooks": {"Stop": [unrelated], "Notification": [old_monitor]}}))

            config_path = codex / "config.toml"
            config_path.write_text('notify = ["say", "still here"]\nmodel = "test"\n')

            with redirect_stdout(io.StringIO()):
                configure.install_hooks(hooks_path, helper, configure.CODEX_HOOK_EVENTS, "codex-hook", False, True)
                configure.install_notify(config_path, helper, False)
                configure.install_hooks(claude_path, helper, configure.CLAUDE_HOOK_EVENTS, "claude-hook", False)

            installed_hooks = json.loads(hooks_path.read_text())
            self.assertEqual(installed_hooks["description"], configure.DESCRIPTION)
            self.assertIn(unrelated, installed_hooks["hooks"]["Stop"])
            self.assertIn("codex-hook", json.dumps(installed_hooks))
            self.assertNotIn("/old/agent-monitor-helper", json.dumps(installed_hooks))
            self.assertNotIn("PermissionRequest", installed_hooks["hooks"])
            self.assertIn("claude-hook", claude_path.read_text())
            self.assertNotIn("Notification", json.loads(claude_path.read_text())["hooks"])
            self.assertIn("model = \"test\"", config_path.read_text())

            with redirect_stdout(io.StringIO()):
                configure.uninstall(hooks_path, config_path, claude_path, False)

            final_hooks = json.loads(hooks_path.read_text())
            self.assertNotIn("description", final_hooks)
            self.assertEqual(final_hooks["hooks"], {"Stop": [unrelated]})
            self.assertEqual(json.loads(claude_path.read_text())["hooks"], {"Stop": [unrelated]})
            self.assertIn('notify = ["say","still here"]', config_path.read_text())
            self.assertIn('model = "test"', config_path.read_text())

    def test_install_chains_codex_app_without_recursive_dispatcher(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            codex = Path(temporary_directory) / ".codex"
            codex.mkdir()
            helper = Path(temporary_directory) / "Agent Monitor.app" / "agent-monitor-helper"
            config_path = codex / "config.toml"
            config_path.write_text('notify = ["/Applications/SkyComputerUseClient", "turn-ended"]\n')

            with redirect_stdout(io.StringIO()):
                configure.install_notify(config_path, helper, False)

            installed = config_path.read_text()
            self.assertIn("SkyComputerUseClient", installed)
            self.assertIn("--previous-notify", installed)
            self.assertIn(str(helper), installed)
            self.assertFalse((codex / "bin" / configure.DISPATCHER_NAME).exists())

    def test_cleanup_removes_recursive_legacy_dispatcher(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            codex = Path(temporary_directory) / ".codex"
            dispatcher = codex / "bin" / configure.DISPATCHER_NAME
            dispatcher.parent.mkdir(parents=True)
            dispatcher.write_text("legacy")
            previous = json.dumps([str(dispatcher)], separators=(",", ":"))
            notify = ["/Applications/SkyComputerUseClient", "turn-ended", "--previous-notify", previous]
            config_path = codex / "config.toml"
            config_path.write_text(
                f"{configure.BEGIN}\n{configure.END}\n"
                f"notify = {json.dumps(notify)}\nmodel = \"test\"\n"
            )

            with redirect_stdout(io.StringIO()):
                configure.cleanup_notify(config_path, False)

            repaired = config_path.read_text()
            self.assertIn('notify = ["/Applications/SkyComputerUseClient","turn-ended"]', repaired)
            self.assertIn('model = "test"', repaired)
            self.assertNotIn("Agent Monitor", repaired)
            self.assertFalse(dispatcher.exists())


if __name__ == "__main__":
    unittest.main()
