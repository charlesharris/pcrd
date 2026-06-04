class HealthController < ApplicationController
  # GET /health
  # Returns 200 with DB stats when healthy, 503 when database is unreachable.
  def show
    ActiveRecord::Base.connection.execute("SELECT 1")

    render json: {
      status:         "ok",
      database:       ActiveRecord::Base.connection.current_database,
      listing_count:  Listing.count,
      user_count:     User.count,
      agent_count:    Agent.count
    }
  rescue ActiveRecord::StatementInvalid, PG::Error => e
    render json: { status: "error", error: e.message }, status: :service_unavailable
  end
end
