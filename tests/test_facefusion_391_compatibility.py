import importlib
from unittest.mock import Mock

import pytest

from facefusion import content_analyser, core, execution, inference_manager, state_manager, voice_extractor


@pytest.mark.parametrize('version,shared', [
    ((1, 24, 4), True), ((1, 25, 1), True), ((1, 25, 2), False),
    ((1, 28, 0), False), ((1, 29, 0), True), ((1, 30, 0), True),
])
def test_cuda_pool_sharing_respects_affected_runtime_versions(monkeypatch, version, shared):
    monkeypatch.setattr(inference_manager, 'INFERENCE_POOL_SET', {'cli': {}, 'ui': {}})
    monkeypatch.setattr(inference_manager, 'has_execution_provider', lambda provider: True)
    monkeypatch.setattr(inference_manager, 'get_onnxruntime_version', lambda: version)
    monkeypatch.setattr(inference_manager, 'resolve_static_inference_providers', lambda *args: [])
    monkeypatch.setattr(inference_manager, 'create_inference_pool', lambda *args: {'model': object()})
    monkeypatch.setattr(inference_manager.process_manager, 'is_checking', lambda: False)
    settings = {'execution_device_ids': [0], 'execution_providers': ['cuda']}
    monkeypatch.setattr(state_manager, 'get_item', settings.get)
    monkeypatch.setattr(inference_manager, 'detect_app_context', lambda: 'cli')
    cli_pool = inference_manager.get_inference_pool('test', ['model'], {})
    monkeypatch.setattr(inference_manager, 'detect_app_context', lambda: 'ui')
    ui_pool = inference_manager.get_inference_pool('test', ['model'], {})
    assert (cli_pool['model'] is ui_pool['model']) is shared


@pytest.mark.parametrize('macos,coreml,expected', [
    (True, True, ['CPUExecutionProvider']), (True, False, []),
    (False, True, []), (False, False, []),
])
def test_content_analyser_provider_override(monkeypatch, macos, coreml, expected):
    monkeypatch.setattr(content_analyser, 'is_macos', lambda: macos)
    monkeypatch.setattr(content_analyser, 'has_execution_provider', lambda provider: coreml)
    assert content_analyser.override_inference_providers() == expected


def test_runtime_version_comes_from_runtime_api(monkeypatch):
    monkeypatch.setattr(execution.onnxruntime, '__version__', 'unrelated-package-version')
    monkeypatch.setattr(execution.onnxruntime, 'get_version_string', Mock(return_value='1.30.0'))
    execution.get_onnxruntime_version.cache_clear()
    try:
        assert execution.get_onnxruntime_version() == (1, 30, 0)
    finally:
        execution.get_onnxruntime_version.cache_clear()


@pytest.mark.parametrize('processor', [
    'age_modifier', 'background_remover', 'deep_swapper', 'expression_restorer',
    'face_debugger', 'face_editor', 'face_enhancer', 'face_swapper',
    'frame_colorizer', 'frame_enhancer',
])
def test_processors_include_voice_dependency(processor):
    module = importlib.import_module(f'facefusion.processors.modules.{processor}.core')
    assert voice_extractor in module.get_common_modules()


def test_official_content_analyser_integrity_check_passes():
    assert core.common_pre_check()
