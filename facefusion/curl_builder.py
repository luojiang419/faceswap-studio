import itertools
import subprocess
import shutil
from functools import lru_cache
from typing import List
from urllib.parse import urlparse

from facefusion import metadata
from facefusion.types import Command


def run(commands : List[Command]) -> List[Command]:
	user_agent = metadata.get('name') + '/' + metadata.get('version')

	return [ shutil.which('curl'), '--user-agent', user_agent, '--location', '--silent', '--ssl-no-revoke' ] + commands


def chain(*commands : List[Command]) -> List[Command]:
	return list(itertools.chain(*commands))


@lru_cache(maxsize = 32)
def resolve_host_ipv4(host : str) -> str:
	if not host or not shutil.which('getent'):
		return ''

	process = subprocess.run([ shutil.which('getent'), 'ahostsv4', host ], stdout = subprocess.PIPE, stderr = subprocess.DEVNULL, text = True)

	if process.returncode == 0:
		for line in process.stdout.splitlines():
			parts = line.split()
			if len(parts) >= 2 and parts[1] == 'STREAM':
				return parts[0]
			if parts:
				return parts[0]
	return ''


def resolve_url(url : str) -> List[Command]:
	host = urlparse(url).hostname
	host_ipv4 = resolve_host_ipv4(host)

	if host and host_ipv4:
		return [ '--resolve', host + ':443:' + host_ipv4 ]
	return []


def ping(url : str) -> List[Command]:
	return resolve_url(url) + [ '-I', url ]


def download(url : str, download_file_path : str) -> List[Command]:
	return resolve_url(url) + [ '--create-dirs', '--continue-at', '-', '--output', download_file_path, url ]


def set_timeout(timeout : int) -> List[Command]:
	return [ '--connect-timeout', str(timeout) ]


def set_retry(retry : int) -> List[Command]:
	return [ '--retry', str(retry) ]
