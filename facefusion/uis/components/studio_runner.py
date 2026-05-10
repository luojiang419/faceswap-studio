from datetime import datetime
import os
from time import sleep
from typing import Optional, Tuple

import gradio

from facefusion import process_manager, state_manager
from facefusion.args import collect_step_args
from facefusion.core import process_step
from facefusion.filesystem import create_directory, get_file_extension, is_directory, is_image, is_video
from facefusion.jobs import job_manager, job_runner, job_store
from facefusion.temp_helper import clear_temp_directory
from facefusion.types import Args
from facefusion.uis.core import get_ui_component
from facefusion.uis.ui_helper import suggest_output_path

STUDIO_RUNNER_START_BUTTON : Optional[gradio.Button] = None
STUDIO_RUNNER_STOP_BUTTON : Optional[gradio.Button] = None
STUDIO_RUNNER_CLEAR_BUTTON : Optional[gradio.Button] = None
STUDIO_RUNNER_QUEUE_BUTTON : Optional[gradio.Button] = None


def render() -> None:
	global STUDIO_RUNNER_START_BUTTON
	global STUDIO_RUNNER_STOP_BUTTON
	global STUDIO_RUNNER_CLEAR_BUTTON
	global STUDIO_RUNNER_QUEUE_BUTTON

	if job_manager.init_jobs(state_manager.get_item('jobs_path')):
		with gradio.Column():
			with gradio.Row():
				STUDIO_RUNNER_START_BUTTON = gradio.Button(
					value = 'START',
					variant = 'primary',
					size = 'sm'
				)
				STUDIO_RUNNER_STOP_BUTTON = gradio.Button(
					value = 'STOP',
					variant = 'primary',
					size = 'sm',
					visible = False
				)
				STUDIO_RUNNER_CLEAR_BUTTON = gradio.Button(
					value = 'CLEAR',
					size = 'sm'
				)
			STUDIO_RUNNER_QUEUE_BUTTON = gradio.Button(
				value = '添加到队列',
				size = 'sm'
			)


def listen() -> None:
	output_image = get_ui_component('output_image')
	output_video = get_ui_component('output_video')

	if output_image and output_video:
		STUDIO_RUNNER_START_BUTTON.click(start, outputs = [ STUDIO_RUNNER_START_BUTTON, STUDIO_RUNNER_STOP_BUTTON ])
		STUDIO_RUNNER_START_BUTTON.click(run_now, outputs = [ STUDIO_RUNNER_START_BUTTON, STUDIO_RUNNER_STOP_BUTTON, output_image, output_video ])
		STUDIO_RUNNER_STOP_BUTTON.click(stop, outputs = [ STUDIO_RUNNER_START_BUTTON, STUDIO_RUNNER_STOP_BUTTON, output_image, output_video ])
		STUDIO_RUNNER_CLEAR_BUTTON.click(clear, outputs = [ output_image, output_video ])
		STUDIO_RUNNER_QUEUE_BUTTON.click(add_to_queue)


def start() -> Tuple[gradio.Button, gradio.Button]:
	while not process_manager.is_processing():
		sleep(0.5)
	return gradio.Button(visible = False), gradio.Button(visible = True)


def run_now() -> Tuple[gradio.Button, gradio.Button, gradio.Image, gradio.Video]:
	step_args = build_step_args()
	output_path = step_args.get('output_path')

	if job_manager.init_jobs(state_manager.get_item('jobs_path')):
		job_id = suggest_studio_job_id()
		create_and_run_job(job_id, step_args)
		state_manager.set_item('output_path', output_path)
	if is_image(step_args.get('output_path')):
		return gradio.Button(visible = True), gradio.Button(visible = False), gradio.Image(value = step_args.get('output_path'), visible = True), gradio.Video(value = None, visible = False)
	if is_video(step_args.get('output_path')):
		return gradio.Button(visible = True), gradio.Button(visible = False), gradio.Image(value = None, visible = False), gradio.Video(value = step_args.get('output_path'), visible = True)
	return gradio.Button(visible = True), gradio.Button(visible = False), gradio.Image(value = None), gradio.Video(value = None)


def add_to_queue() -> None:
	step_args = build_step_args()
	output_path = step_args.get('output_path')

	if not job_manager.init_jobs(state_manager.get_item('jobs_path')):
		gradio.Warning('任务队列目录初始化失败')
		return

	job_id = suggest_studio_job_id()
	step_args['output_path'] = resolve_studio_output_path(output_path, step_args.get('target_path'), job_id)

	for key in job_store.get_job_keys():
		state_manager.sync_item(key) #type:ignore[arg-type]

	if job_manager.create_job(job_id) and job_manager.add_step(job_id, step_args) and job_manager.submit_job(job_id):
		state_manager.set_item('output_path', output_path)
		gradio.Info(f'任务已加入生成队列: {job_id}')
		return

	state_manager.set_item('output_path', output_path)
	gradio.Warning('任务加入生成队列失败')


def build_step_args() -> Args:
	step_args = collect_step_args()
	output_path = step_args.get('output_path')
	target_path = step_args.get('target_path')

	if is_directory(output_path):
		step_args['output_path'] = resolve_studio_output_path(output_path, target_path)
	elif not output_path and target_path:
		step_args['output_path'] = resolve_studio_output_path(state_manager.get_item('output_path'), target_path)
	elif is_directory(state_manager.get_item('output_path')):
		step_args['output_path'] = resolve_studio_output_path(state_manager.get_item('output_path'), target_path)

	if is_directory(step_args.get('output_path')):
		step_args['output_path'] = suggest_output_path(step_args.get('output_path'), target_path)
	return step_args


def resolve_studio_output_path(base_output_path : str, target_path : str, output_name : Optional[str] = None) -> Optional[str]:
	if not target_path:
		return base_output_path
	if is_image(target_path):
		target_directory = os.path.join(base_output_path, 'img') if is_directory(base_output_path) else base_output_path
	elif is_video(target_path):
		target_directory = os.path.join(base_output_path, 'video') if is_directory(base_output_path) else base_output_path
	else:
		target_directory = base_output_path

	if is_directory(base_output_path):
		create_directory(target_directory)
		target_extension = get_file_extension(target_path) or ''
		file_name = output_name or ('run_' + datetime.now().strftime('%Y%m%d_%H%M%S'))
		return os.path.join(target_directory, file_name + target_extension)
	return target_directory


def suggest_studio_job_id() -> str:
	existing_job_ids = []
	for job_status in [ 'drafted', 'queued', 'completed', 'failed' ]:
		existing_job_ids.extend(job_manager.find_job_ids(job_status))

	max_index = 0
	for job_id in existing_job_ids:
		parts = job_id.split('_', 1)
		if len(parts) == 2 and parts[0].isdigit():
			max_index = max(max_index, int(parts[0]))
	return f'{max_index + 1:03d}_{datetime.now().strftime("%Y%m%d_%H%M%S")}'


def create_and_run_job(job_id : str, step_args : Args) -> bool:
	for key in job_store.get_job_keys():
		state_manager.sync_item(key) #type:ignore[arg-type]

	return job_manager.create_job(job_id) and job_manager.add_step(job_id, step_args) and job_manager.submit_job(job_id) and job_runner.run_job(job_id, process_step)


def stop() -> Tuple[gradio.Button, gradio.Button, gradio.Image, gradio.Video]:
	process_manager.stop()
	return gradio.Button(visible = True), gradio.Button(visible = False), gradio.Image(value = None), gradio.Video(value = None)


def clear() -> Tuple[gradio.Image, gradio.Video]:
	while process_manager.is_processing():
		sleep(0.5)
	if state_manager.get_item('target_path'):
		clear_temp_directory(state_manager.get_item('target_path'))
	return gradio.Image(value = None), gradio.Video(value = None)
