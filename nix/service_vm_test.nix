# Boots a NixOS VM with services.uuidv7 enabled and checks the machine-wide
# service end to end: socket ownership and modes, two users sharing one
# service, refused control commands, crash restart with the counter kept, and
# the client's try-again/error policy once systemd's start limit is hit.
{ self, pkgs }:
pkgs.testers.runNixOSTest {
	name = "uuidv7-service";
	nodes.machine = {
		imports = [ self.nixosModules.default ];
		services.uuidv7.enable = true;
		users.users.alice.isNormalUser = true;
		users.users.bob.isNormalUser = true;
	};
	# The NixOS test driver takes its script in Python.
	testScript = ''
import re

def as_user(user, cmd):
	return machine.succeed(f"su - {user} -c '{cmd}'")

def run_as(user, cmd):
	rc, out = machine.execute(f"su - {user} -c '{cmd} 2>&1'")
	return rc, out

def served():
	m = re.search(r'"uuids_served":(\d+)', machine.succeed("uuidv7 --api sj"))
	assert m is not None
	return int(m.group(1))

def main_pid():
	return machine.succeed("systemctl show -p MainPID --value uuidv7.service").strip()

machine.wait_for_unit("uuidv7.socket")

with subtest("the socket directory is root-owned 0755 and the socket is 0666"):
	assert machine.succeed("stat -c '%U %a' /run/uuidv7").strip() == "root 755"
	assert machine.succeed("stat -c '%a' /run/uuidv7/uuidv7.sock").strip() == "666"

with subtest("two users are served by the one service, with no warnings"):
	rc, out = run_as("alice", "uuidv7")
	assert rc == 0 and re.fullmatch(r"[0-9a-f]{32}\n", out), out
	machine.succeed("systemctl is-active uuidv7.service")
	before = served()
	last = ""
	for i in range(10):
		for user in ("alice", "bob"):
			rc, out = run_as(user, "uuidv7")
			assert rc == 0 and re.fullmatch(r"[0-9a-f]{32}\n", out), out
			assert out > last, f"{out} after {last}"
			last = out
	assert served() == before + 20

with subtest("the state is private to the service's dynamic user"):
	owner = machine.succeed("stat -c '%U %a' /run/private/uuidv7-state").split()
	assert owner[0] != "root" and owner[1] == "700", owner
	# The daemon writes its counter through to the file (no silent in-memory fallback).
	assert re.fullmatch(r"\d+:\d+", machine.succeed("cat /run/private/uuidv7-state/sequence")), "no counter state"
	machine.fail("su - alice -c 'cat /run/private/uuidv7-state/sequence'")

with subtest("clients cannot stop, restart or reconfigure logging of the service"):
	pid = main_pid()
	for verb in ("+++", "r", "l"):
		out = as_user("alice", f"uuidv7 --api {verb}")
		assert out.startswith("ERR ") and "service manager" in out, out
	machine.succeed("systemctl is-active uuidv7.service")
	assert main_pid() == pid

with subtest("a crashed service is restarted and continues the sequence"):
	last = as_user("alice", "uuidv7")
	pid = main_pid()
	machine.succeed(f"kill -9 {pid}")
	machine.wait_until_succeeds(f"test \"$(systemctl show -p MainPID --value uuidv7.service)\" != {pid}")
	rc, out = run_as("bob", "uuidv7")
	assert rc == 0 and out > last, f"{out} after {last}"

with subtest("past the start limit, clients say try again three times, then fail"):
	for attempt in range(6):
		if machine.execute("systemctl is-failed uuidv7.service")[0] == 0:
			break
		pid = main_pid()
		if pid != "0":
			machine.succeed(f"kill -9 {pid}")
		machine.wait_until_succeeds(
			f"systemctl is-failed uuidv7.service || test \"$(systemctl show -p MainPID --value uuidv7.service)\" != {pid}")
	machine.succeed("systemctl is-failed uuidv7.service")
	results = [run_as("alice", "timeout 10 uuidv7") for i in range(4)]
	assert [rc for rc, out in results] == [75, 75, 75, 1], results
	assert all("please try again" in out for rc, out in results[:3]), results
	assert "not running" in results[3][1], results

with subtest("after an administrator resets it, the service serves again"):
	machine.succeed("systemctl reset-failed uuidv7.service uuidv7.socket")
	machine.succeed("systemctl restart uuidv7.socket")
	rc, out = run_as("alice", "uuidv7")
	assert rc == 0 and re.fullmatch(r"[0-9a-f]{32}\n", out), out
'';
}
