require 'line/bot'
require 'httpclient'
require 'json'

class WebhookController < ApplicationController
  protect_from_forgery except: [:callback] # CSRF対策無効化

  def client
    @client ||= Line::Bot::Client.new { |config|
      config.channel_secret = ENV["LINE_CHANNEL_SECRET"]
      config.channel_token = ENV["LINE_CHANNEL_TOKEN"]
    }
  end

  def callback
    body = request.body.read

    signature = request.env['HTTP_X_LINE_SIGNATURE']
    unless client.validate_signature(body, signature)
      head 470
    end

    events = client.parse_events_from(body)
    events.each { |event|
      case event
      when Line::Bot::Event::Message
        case event.type
        when Line::Bot::Event::MessageType::Text
          if event.message['text'].eql?('日本') then
            message = {
              type: 'text',
              text: '東京'
            }
          elsif event.message['text'].eql?('コスタリカ') then
            message = {
              type: 'text',
              text: 'サンホセ'
            }
          elsif event.message['text'].eql?('JP') then
            # JPと入力したら日本の2020年の祝日リストを返す
            get_holidays(event.message['text'], '2020')
            message = {
              type: 'text',
              text: holidays_list
            }
          else
            # Nager.Dateをコール
            # api/v2/AvailableCountriesで辞書型リストゲット
            # contrycodes={'code': 'name'}
            message = {
              type: 'text',
              text: event.message['text']
            }
          end
          client.reply_message(event['replyToken'], message)
        when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
          response = client.get_message_content(event.message['id'])
          tf = Tempfile.open("content")
          tf.write(response.body)
        end
      end
    }
    head :ok
  end

  def get_holidays(countrycode, year, retry_count = 10)
    raise ArgumentError, 'too many HTTP redirects' if retry_count == 0

    uri = Addressable::URI.parse("https://date.nager.at/Api/v1/Get/#{countrycode}/#{year}")

    begin
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.open_timeout = 5
        http.read_timeout = 10
        http.get(uri.request_uri)
      end

      case response
        when Net::HTTPSuccess
          json = JSON.parse(response.body)
          if json['results_returned'] == 0
            nil
          else
            json
          end

        when Net::HTTPRedirection
          location = response['location']
          Rails.logger.error(warn "redirected to #{location}")
          search_area(form_words, start_date, end_date, retry_count - 1)
        else
          Rails.logger.error([uri.to_s, response.value].join(" : "))
      end

    rescue => e
      Rails.logger.error(e.message)
      raise e
    end
  end
end