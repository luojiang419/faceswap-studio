from facefusion import choices, metadata, state_manager
from facefusion.face_landmarker import collect_model_downloads, create_static_model_set
from facefusion.processors.modules.face_swapper import choices as face_swapper_choices


def test_facefusion_390_core_models_are_available() -> None:
	state_manager.init_item('download_providers', [ 'huggingface' ])
	state_manager.init_item('face_landmarker_model', 'hrffa')

	model_hashes, model_sources = collect_model_downloads()

	assert metadata.get('version') == '3.9.0'
	assert 'hrffa' in choices.face_landmarker_models
	assert 'hrffa' in create_static_model_set('full')
	assert 'hrffa' in model_hashes
	assert 'hrffa' in model_sources
	assert 'alphaface_256' in face_swapper_choices.face_swapper_models
	assert face_swapper_choices.face_swapper_set['alphaface_256'] == [
		'256x256',
		'512x512',
		'768x768',
		'1024x1024',
	]
