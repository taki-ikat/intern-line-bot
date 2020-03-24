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
            # 取得先URL
            url_holiday = 'https://date.nager.at/Api/v1/Get/'

            params = {
              countrycode = 'JP'
              year = '2020'
            }

            client = HTTPClient.new
            request = client.get(url_holiday, params)
            response = JSON.parse(require.body)

            # 祝日保管用Array
            holiday_list = []
            # 応答メッセージ
            res_holiday = {}

            response.each do |res|
              holiday_list.append res["name"]
              res_holiday += res["name"]
              res_holiday += "¥n"
            end
            message = {
              type: 'text',
              text: res_holiday
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
end
