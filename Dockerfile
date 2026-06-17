FROM library/ruby:4.0.1-alpine
RUN apk update && apk upgrade && \
    apk add --no-cache make g++ git
RUN mkdir -p /usr/src/app
WORKDIR /usr/src/app
COPY ./Gemfile /usr/src/app/
RUN bundle install
COPY ./ /usr/src/app
EXPOSE 80
CMD ["rackup", "config.ru", "--host", "0.0.0.0", "--port", "80"]
