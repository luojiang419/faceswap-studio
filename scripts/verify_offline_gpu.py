"""在解包后的环境验证 CUDA 计算和真实本机模型，不接受静默回退到 CPU。"""
import argparse
import json
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    sys.path.insert(0, str(root / 'scripts'))
    from launch_original_webui import prepare_environment
    prepare_environment(root)
    import numpy as np
    import onnx
    from onnx import TensorProto, helper, numpy_helper
    import onnxruntime as ort
    ort.preload_dlls(directory='')
    report = {'python': sys.version, 'prefix': sys.prefix, 'basePrefix': sys.base_prefix,
              'onnxruntime': ort.__version__, 'ortCudaBuild': ort.cuda_version, 'providers': ort.get_available_providers()}
    x = helper.make_tensor_value_info('x', TensorProto.FLOAT, [1, 1, 8, 8])
    y = helper.make_tensor_value_info('y', TensorProto.FLOAT, [1, 1, 6, 6])
    weight = np.ones((1, 1, 3, 3), np.float32)
    graph = helper.make_graph([helper.make_node('Conv', ['x', 'weight'], ['y'])], 'cuda-smoke', [x], [y],
                              [numpy_helper.from_array(weight, 'weight')])
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 18)], ir_version=9)
    options = ort.SessionOptions()
    options.enable_profiling = True
    options.profile_file_prefix = str(args.report.with_suffix(''))
    session = ort.InferenceSession(model.SerializeToString(), sess_options=options, providers=['CUDAExecutionProvider'])
    assert session.get_providers()[0] == 'CUDAExecutionProvider', 'CUDA 加载失败，禁止把 CPU 回退当 GPU 成功'
    output = session.run(None, {'x': np.ones((1, 1, 8, 8), np.float32)})[0]
    np.testing.assert_allclose(output, np.full((1, 1, 6, 6), 9, np.float32))
    events = json.loads(Path(session.end_profiling()).read_text())
    used = sorted({e['args']['provider'] for e in events if e.get('args', {}).get('provider')})
    assert 'CUDAExecutionProvider' in used
    report['convolution'] = {'correct': True, 'executedProviders': used}
    model_path = root / '.assets/models/span_kendata_x4.onnx'
    real = ort.InferenceSession(str(model_path), providers=['CUDAExecutionProvider'])
    assert real.get_providers()[0] == 'CUDAExecutionProvider'
    info = real.get_inputs()[0]
    result = real.run(None, {info.name: np.full((1, 3, 16, 16), .5, np.float32)})[0]
    assert result.shape == (1, 3, 64, 64) and np.isfinite(result).all()
    report['bundledModel'] = {'name': model_path.name, 'outputShape': list(result.shape), 'finite': True,
                             'providers': real.get_providers()}
    report['ok'] = True
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2), 'utf-8')
    print(json.dumps(report, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
