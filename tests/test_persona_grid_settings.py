"""人物库倍率的配置边界和落盘恢复，不访问真实用户数据。"""

import json

import pytest

from tests.test_app_server_workspace_options import create_runtime


@pytest.mark.parametrize('value, expected', [
    (None, 100.0), (True, 100.0), ('bad', 100.0),
    (float('nan'), 100.0), (float('inf'), 100.0),
    (10 ** 1000, 100.0), (-5, 10.0), (10, 10.0),
    (137, 137.0), (800, 800.0), (900, 800.0),
])
def test_persona_grid_scale_round_trip(tmp_path, value, expected):
    runtime = create_runtime(tmp_path)
    runtime._settings_template_path.parent.mkdir(parents=True, exist_ok=True)
    runtime._settings = runtime._default_settings()
    result = runtime.update_settings({'persona_grid_scale': value})
    assert result['persona_grid_scale'] == expected
    assert json.loads(runtime._settings_path.read_text(encoding='utf-8'))['persona_grid_scale'] == expected

    # 模拟退出后重新启动：从同一个配置目录恢复。
    restarted = create_runtime(tmp_path)
    assert restarted._load_settings()['persona_grid_scale'] == expected


def test_missing_scale_defaults_and_other_settings_preserve_it(tmp_path):
    runtime = create_runtime(tmp_path)
    runtime._settings_template_path.parent.mkdir(parents=True, exist_ok=True)
    assert runtime._load_settings()['persona_grid_scale'] == 100.0
    runtime._settings = runtime._default_settings()
    runtime.update_settings({'persona_grid_scale': 230})
    runtime.update_settings({'theme': 'dark', 'sidebar_expanded': True})
    assert runtime.get_settings()['persona_grid_scale'] == 230.0
    assert runtime._load_settings()['persona_grid_scale'] == 230.0
