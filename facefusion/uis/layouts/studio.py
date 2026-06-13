import gradio

from facefusion.uis.core import get_ui_launch_kwargs
from facefusion.uis.components import (
	about,
	age_modifier_options,
	background_remover_options,
	common_options,
	deep_swapper_options,
	download,
	execution,
	execution_thread_count,
	expression_restorer_options,
	face_debugger_options,
	face_detector,
	face_editor_options,
	face_enhancer_options,
	face_landmarker,
	face_masker,
	face_selector,
	face_swapper_options,
	frame_colorizer_options,
	frame_enhancer_options,
	lip_syncer_options,
	memory,
	output,
	output_options,
	preview,
	preview_options,
	processors,
	source,
	studio_runner,
	target,
	temp_frame,
	terminal,
	trim_frame,
	voice_extractor,
)


def pre_check() -> bool:
	return True


def render() -> gradio.Blocks:
	with gradio.Blocks() as layout:
		with gradio.Row():
			with gradio.Column(scale = 4):
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					about.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					processors.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					age_modifier_options.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					background_remover_options.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					deep_swapper_options.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					expression_restorer_options.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					face_debugger_options.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					face_editor_options.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					face_enhancer_options.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					face_swapper_options.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					frame_colorizer_options.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					frame_enhancer_options.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					lip_syncer_options.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					voice_extractor.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					execution.render()
					execution_thread_count.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					download.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					memory.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					temp_frame.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					output_options.render()
			with gradio.Column(scale = 4):
				with gradio.Blocks(elem_classes = [ 'studio-card', 'studio-source-pane' ]):
					source.render()
				with gradio.Blocks(elem_classes = [ 'studio-card', 'studio-target-pane' ]):
					target.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					output.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					terminal.render()
				with gradio.Blocks(elem_classes = [ 'studio-card', 'studio-runner-pane' ]):
					studio_runner.render()
			with gradio.Column(scale = 7):
				with gradio.Blocks(elem_classes = [ 'studio-card', 'studio-preview-pane' ]):
					preview.render()
					preview_options.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					trim_frame.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					face_selector.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					face_masker.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					face_detector.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					face_landmarker.render()
				with gradio.Blocks(elem_classes = [ 'studio-card' ]):
					common_options.render()
	return layout


def listen() -> None:
	processors.listen()
	age_modifier_options.listen()
	background_remover_options.listen()
	deep_swapper_options.listen()
	expression_restorer_options.listen()
	face_debugger_options.listen()
	face_editor_options.listen()
	face_enhancer_options.listen()
	face_swapper_options.listen()
	frame_colorizer_options.listen()
	frame_enhancer_options.listen()
	lip_syncer_options.listen()
	execution.listen()
	execution_thread_count.listen()
	download.listen()
	memory.listen()
	temp_frame.listen()
	output_options.listen()
	source.listen()
	target.listen()
	output.listen()
	studio_runner.listen()
	terminal.listen()
	preview.listen()
	preview_options.listen()
	trim_frame.listen()
	face_selector.listen()
	face_masker.listen()
	face_detector.listen()
	face_landmarker.listen()
	voice_extractor.listen()
	common_options.listen()


def run(ui : gradio.Blocks) -> None:
	ui.launch(**get_ui_launch_kwargs())
