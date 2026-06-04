FROM ruby:3.2-slim

RUN apt-get update && apt-get install -y \
      build-essential \
      libpq-dev \
      && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile .
RUN bundle install

COPY . .

ENV RAILS_ENV=development
ENV RAILS_LOG_TO_STDOUT=true

EXPOSE 3000

CMD ["bundle", "exec", "puma", "-C", "config/puma.rb"]
