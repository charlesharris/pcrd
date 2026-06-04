# frozen_string_literal: true

module Pcrd
  module Demo
    # Generates realistic-looking fake data for the demo schema.
    # Uses no external dependencies — all data is synthesized from built-in arrays.
    class Generator
      BATCH_SIZE = 500

      FIRST_NAMES = %w[
        James Mary Robert Patricia John Jennifer Michael Linda William Barbara
        David Susan Richard Karen Joseph Lisa Thomas Betty Charles Margaret
        Christopher Sandra Daniel Ashley Paul Emily Mark Donna George Carol
        Steven Ruth Kenneth Sharon Edward Michelle Brian Cynthia Ronald Laura
        Anthony Kimberly Kevin Deborah Jason Rebecca Jeffrey Sharon Gary Helen
      ].freeze

      LAST_NAMES = %w[
        Smith Johnson Williams Brown Jones Garcia Miller Davis Wilson Anderson
        Taylor Thomas Hernandez Moore Martin Jackson Thompson White Lopez Lee
        Gonzalez Harris Clark Lewis Robinson Walker Perez Hall Young Allen
        Sanchez Wright King Scott Green Baker Adams Nelson Hill Ramirez Campbell
        Mitchell Roberts Carter Phillips Evans Turner Torres Parker Collins Edwards
      ].freeze

      EMAIL_DOMAINS = %w[gmail.com yahoo.com hotmail.com outlook.com icloud.com].freeze

      CITIES_STATES = [
        ["New York",      "NY"], ["Los Angeles",   "CA"], ["Chicago",       "IL"],
        ["Houston",       "TX"], ["Phoenix",        "AZ"], ["Philadelphia",  "PA"],
        ["San Antonio",   "TX"], ["San Diego",      "CA"], ["Dallas",        "TX"],
        ["San Jose",      "CA"], ["Austin",         "TX"], ["Jacksonville",  "FL"],
        ["Fort Worth",    "TX"], ["Columbus",       "OH"], ["Charlotte",     "NC"],
        ["San Francisco", "CA"], ["Indianapolis",   "IN"], ["Seattle",       "WA"],
        ["Denver",        "CO"], ["Nashville",      "TN"], ["Oklahoma City", "OK"],
        ["El Paso",       "TX"], ["Boston",         "MA"], ["Portland",      "OR"],
        ["Las Vegas",     "NV"], ["Memphis",        "TN"], ["Louisville",    "KY"],
        ["Baltimore",     "MD"], ["Milwaukee",      "WI"], ["Albuquerque",   "NM"],
        ["Tucson",        "AZ"], ["Fresno",         "CA"], ["Sacramento",    "CA"],
        ["Mesa",          "AZ"], ["Kansas City",    "MO"], ["Atlanta",       "GA"],
        ["Omaha",         "NE"], ["Colorado Springs","CO"],["Raleigh",       "NC"],
        ["Long Beach",    "CA"], ["Virginia Beach",  "VA"], ["Minneapolis",  "MN"],
      ].freeze

      STREET_SUFFIXES = %w[St Ave Blvd Dr Rd Way Ln Ct Pl Ter Circle].freeze
      STREET_NAMES    = %w[
        Oak Maple Pine Cedar Elm Main Park Lake Hill River View Forest Sunset
        Highland Meadow Ridge Valley Spring Garden Grove Willow Cherry Apple
      ].freeze

      DESCRIPTIONS = [
        "Charming property in a desirable neighborhood.",
        "Move-in ready home with modern upgrades throughout.",
        "Spacious floor plan with abundant natural light.",
        "Updated kitchen and baths, hardwood floors.",
        "Corner lot with mature landscaping and privacy.",
        "Open concept living with high-end finishes.",
        "Well-maintained property close to top-rated schools.",
        "Quiet cul-de-sac location, walking distance to parks.",
        "Investor opportunity or perfect primary residence.",
        "Stunning views and outdoor entertaining space.",
        "Classic architecture with contemporary updates.",
        "Energy-efficient with solar panels and smart features.",
      ].freeze

      def initialize(pool, seed: 42)
        @pool = pool
        @rng  = Random.new(seed)
      end

      # Generate users, agents, then listings in dependency order.
      # Returns hash with row counts generated for each table.
      def generate(listing_count:)
        user_count  = [[(listing_count / 10).ceil, 50].max, 500].min
        agent_count = [[(listing_count / 20).ceil, 10].max, 100].min

        $stdout.puts "  Generating #{user_count} users..."
        user_ids  = insert_users(user_count)

        $stdout.puts "  Generating #{agent_count} agents..."
        agent_ids = insert_agents(agent_count, user_ids: user_ids)

        $stdout.puts "  Generating #{listing_count} listings..."
        insert_listings(listing_count, agent_ids: agent_ids)

        { users: user_count, agents: agent_count, listings: listing_count }
      end

      private

      def insert_users(count)
        ids = []
        rows_batch(count) do |i|
          first = FIRST_NAMES.sample(random: @rng)
          last  = LAST_NAMES.sample(random: @rng)
          email = "#{first.downcase}.#{last.downcase}#{i}@#{EMAIL_DOMAINS.sample(random: @rng)}"
          [
            "false",
            email,
            first,
            last,
            random_past_timestamp(years: 5)
          ]
        end.each_slice(BATCH_SIZE) do |batch|
          result = @pool.exec(
            "INSERT INTO users (is_admin, email, first_name, last_name, created_at) " \
            "VALUES #{placeholders(batch, 5)} RETURNING id",
            batch.flatten
          )
          ids.concat(result.column_values(0).map(&:to_i))
        end
        ids
      end

      def insert_agents(count, user_ids:)
        ids = []
        rows_batch(count) do |_i|
          hired = random_past_date(years: 10)
          [
            user_ids.sample(random: @rng),
            "LIC-#{@rng.rand(100_000..999_999)}",
            "true",
            format("%.4f", @rng.rand(0.020..0.065)),
            hired,
            random_past_timestamp(years: 5)
          ]
        end.each_slice(BATCH_SIZE) do |batch|
          result = @pool.exec(
            "INSERT INTO agents (user_id, license_number, active, commission_rate, hired_at, created_at) " \
            "VALUES #{placeholders(batch, 6)} RETURNING id",
            batch.flatten
          )
          ids.concat(result.column_values(0).map(&:to_i))
        end
        ids
      end

      def insert_listings(count, agent_ids:)
        rows_batch(count) do |_i|
          city, state = CITIES_STATES.sample(random: @rng)
          sqft        = @rng.rand(500..7_500)
          price       = (@rng.rand(80_000..4_500_000) / 1000.0 * 1000).round(2)
          ppsf        = (price / sqft).round(4)
          bedrooms    = @rng.rand(1..6)
          bathrooms   = @rng.rand(1..4)
          year_built  = @rng.rand(1920..2024)
          lat         = @rng.rand(25.0..48.0).round(6)
          lon         = @rng.rand(-124.0..-67.0).round(6)
          listed_at   = random_past_timestamp(years: 3)
          street_num  = @rng.rand(1..9_999)
          street      = "#{street_num} #{STREET_NAMES.sample(random: @rng)} " \
                        "#{STREET_SUFFIXES.sample(random: @rng)}"
          zip         = format("%05d", @rng.rand(10_000..99_999))
          [
            "true",
            price,
            bedrooms,
            "false",
            listed_at,
            sqft,
            "false",
            ppsf,
            lon,
            year_built,
            listed_at,
            bathrooms,
            year_built > 2020 ? (@rng.rand < 0.5 ? "true" : "false") : "false",
            lat,
            DESCRIPTIONS.sample(random: @rng),
            street,
            city,
            state,
            zip,
            agent_ids.sample(random: @rng)
          ]
        end.each_slice(BATCH_SIZE) do |batch|
          @pool.exec(
            "INSERT INTO listings (" \
            "  active, list_price, bedrooms, has_garage, listed_at, square_feet," \
            "  is_featured, price_per_sqft, longitude, year_built, created_at," \
            "  bathrooms, is_new_construction, latitude, description," \
            "  address_line1, city, state_code, zip_code, agent_id" \
            ") VALUES #{placeholders(batch, 20)}",
            batch.flatten
          )
        end
      end

      # Builds an array of rows by calling block(index) for each row.
      def rows_batch(count, &block)
        count.times.map(&block)
      end

      # Builds $1,$2,$3,... placeholder groups for multi-row insert.
      def placeholders(rows, cols_per_row)
        rows.each_with_index.map do |_, i|
          base = i * cols_per_row + 1
          "(#{(base..base + cols_per_row - 1).map { "$#{_1}" }.join(",")})"
        end.join(",")
      end

      def random_past_timestamp(years:)
        seconds_ago = @rng.rand(0..(years * 365 * 24 * 3600))
        offset = Time.now.to_i - seconds_ago
        Time.at(offset).strftime("%Y-%m-%d %H:%M:%S")
      end

      def random_past_date(years:)
        days_ago = @rng.rand(0..(years * 365))
        (Date.today - days_ago).to_s
      end
    end
  end
end
