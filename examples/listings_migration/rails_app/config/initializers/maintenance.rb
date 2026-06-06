# Maintenance mode middleware.
#
# To enable maintenance mode before pcrd cutover:
#   docker compose stop rails_app
#   docker compose run -e MAINTENANCE_MODE=true rails_app
#
# Or create the file:
#   docker compose exec rails_app touch /app/tmp/maintenance.txt
#
# To disable:
#   docker compose exec rails_app rm /app/tmp/maintenance.txt

class MaintenanceModeMiddleware
  BODY = [{ status: "maintenance", 
message: "Service temporarily unavailable for maintenance. Please try again shortly." }.to_json].freeze

  def initialize(app)
    @app = app
  end

  def call(env)
    if maintenance?
      [503, { "Content-Type" => "application/json" }, BODY]
    else
      @app.call(env)
    end
  end

  private

  def maintenance?
    ENV["MAINTENANCE_MODE"] == "true" ||
      File.exist?(File.join(File.dirname(__FILE__), "../../tmp/maintenance.txt"))
  end
end

Rails.application.config.middleware.insert_before(
  ActionDispatch::RequestId,
  MaintenanceModeMiddleware
)
