Rails.application.routes.draw do
  # Health check — used to verify the app is running and the DB is reachable
  get  "/health",   to: "health#show"

  # Listings — the primary resource for the migration demo
  get  "/listings",     to: "listings#index"
  post "/listings",     to: "listings#create"
  get  "/listings/:id", to: "listings#show"

  # Stats endpoint — shows counts across all tables
  get  "/stats", to: "stats#show"
end
