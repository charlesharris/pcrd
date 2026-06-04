class StatsController < ApplicationController
  # GET /stats
  # Summary stats across all tables — good for confirming the migration
  # preserved all rows after cutover.
  def show
    render json: {
      tables: {
        listings: {
          count:   Listing.count,
          max_id:  Listing.maximum(:id),
          id_type: id_type_for("listings")
        },
        users: {
          count:   User.count,
          max_id:  User.maximum(:id),
          id_type: id_type_for("users")
        },
        agents: {
          count:   Agent.count,
          max_id:  Agent.maximum(:id),
          id_type: id_type_for("agents")
        }
      }
    }
  end

  private

  # Returns the PostgreSQL type name for the id column — "integer" on source,
  # "bigint" on target. A clear signal of which cluster the app is talking to.
  def id_type_for(table_name)
    result = ActiveRecord::Base.connection.execute(
      "SELECT data_type FROM information_schema.columns " \
      "WHERE table_name = '#{table_name}' AND column_name = 'id'"
    )
    result.first&.fetch("data_type", "unknown") || "unknown"
  end
end
