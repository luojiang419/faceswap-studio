from shutil import which

from facefusion import metadata
from facefusion.curl_builder import chain, ping, resolve_proxy_commands, run, set_timeout


def test_run(monkeypatch) -> None:
	monkeypatch.setenv('FACEFUSION_DISABLE_PROXY', '0')
	monkeypatch.delenv('FACEFUSION_PROXY_URL', raising = False)
	user_agent = metadata.get('name') + '/' + metadata.get('version')

	assert run([]) == [ which('curl'), '--user-agent', user_agent, '--location', '--silent', '--ssl-no-revoke' ]


def test_resolve_proxy_commands(monkeypatch) -> None:
	monkeypatch.delenv('FACEFUSION_PROXY_URL', raising = False)
	monkeypatch.setenv('FACEFUSION_DISABLE_PROXY', '1')

	assert resolve_proxy_commands() == [ '--proxy', '', '--noproxy', '*' ]

	monkeypatch.setenv('FACEFUSION_DISABLE_PROXY', '0')

	assert resolve_proxy_commands() == []

	monkeypatch.setenv('FACEFUSION_PROXY_URL', 'http://127.0.0.1:7890')

	assert resolve_proxy_commands() == [ '--proxy', 'http://127.0.0.1:7890' ]


def test_chain() -> None:
	assert chain(
		ping(metadata.get('url')),
		set_timeout(5)
	) == [ '-I', metadata.get('url'), '--connect-timeout', '5' ]
