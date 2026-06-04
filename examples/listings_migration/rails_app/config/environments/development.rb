Rails.application.configure do
  config.cache_classes = false
  config.eager_load    = false

  config.consider_all_requests_local = true
  config.action_controller.raise_on_open_redirects = true
end
