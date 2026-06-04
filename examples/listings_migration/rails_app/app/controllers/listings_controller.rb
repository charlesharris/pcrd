class ListingsController < ApplicationController
  LISTINGS_PER_PAGE = 20

  # GET /listings
  # Returns paginated listings with total count.
  # Useful for confirming the app stays live during migration (poll this endpoint).
  def index
    page     = [params[:page].to_i, 1].max
    listings = Listing.order(id: :asc)
                      .limit(LISTINGS_PER_PAGE)
                      .offset((page - 1) * LISTINGS_PER_PAGE)

    render json: {
      listings:    listings.map { listing_json(_1) },
      total_count: Listing.count,
      page:        page,
      per_page:    LISTINGS_PER_PAGE
    }
  end

  # GET /listings/:id
  def show
    listing = Listing.find(params[:id])
    render json: listing_json(listing)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Listing #{params[:id]} not found" }, status: :not_found
  end

  # POST /listings
  # Creates a new listing to demonstrate writes during migration.
  def create
    listing = Listing.new(listing_params)

    if listing.save
      render json: listing_json(listing), status: :created
    else
      render json: { errors: listing.errors.full_messages }, status: :unprocessable_entity
    end
  end

  private

  def listing_params
    params.require(:listing).permit(
      :list_price, :bedrooms, :bathrooms, :square_feet,
      :address_line1, :city, :state_code, :zip_code,
      :description, :has_garage, :year_built,
      :latitude, :longitude, :agent_id
    )
  end

  def listing_json(listing)
    {
      id:            listing.id,
      list_price:    listing.list_price,
      city:          listing.city,
      state_code:    listing.state_code,
      address_line1: listing.address_line1,
      bedrooms:      listing.bedrooms,
      bathrooms:     listing.bathrooms,
      square_feet:   listing.square_feet,
      listed_at:     listing.listed_at,
      created_at:    listing.created_at
    }
  end
end
