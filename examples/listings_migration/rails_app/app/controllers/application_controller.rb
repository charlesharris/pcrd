class ApplicationController < ActionController::API
  rescue_from ActiveRecord::StatementInvalid do |e|
    render json: { error: "Database error", detail: e.message }, status: :service_unavailable
  end
end
