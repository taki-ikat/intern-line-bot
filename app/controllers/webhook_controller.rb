require 'line/bot'
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
          # 入力した国コードから祝日リストを取得し，LINEの応答メッセージとしてセットしてLINE上に返す．
          client.reply_message(event['replyToken'], generate_message(fetch_holidays(event.message['text'], Time.zone.today.year)))
        when Line::Bot::Event::MessageType::Image, Line::Bot::Event::MessageType::Video
          response = client.get_message_content(event.message['id'])
          tf = Tempfile.open("content")
          tf.write(response.body)
        end
      end
    }
    head :ok
  end

  private

  MAX_RETRY_COUNT = 3
  API_URL = "https://date.nager.at/Api"

  # 返すテキストメッセージの設定
  def generate_message(text)
    {
      type: 'text',
      text: text
    }
  end

  # 国コードと年に該当する祝日リストを返す
  def fetch_holidays(countrycode, year, retry_count = MAX_RETRY_COUNT)
    return "タイムアウトしました。\n時間をおいてみるとうまくいくかもしれません。" if retry_count <= 0

    begin
      uri = URI.parse("#{API_URL}/v1/Get/#{countrycode}/#{year}")

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
        http.open_timeout = 5
        http.read_timeout = 10
        http.get(uri.request_uri)
      end

      case response
        when Net::HTTPSuccess
          holidays = JSON.parse(response.body)
          # 祝日名のキー設定
          if countrycode == 'JP'   # 日本なら日本語で返す
            country = "localName"
          else
            country = "name"       # それ以外は英語で返す
          end
          return holidays.map {|holiday| "#{holiday["date"]}:#{holiday[country]}"}.join("\n")

        when Net::HTTPNotFound
          "存在しない国コードです"

        else
          Rails.logger.error([uri.to_s, response].join(" : "))
          "調子が悪いみたいです。\n時間をおいてみるとうまくいくかもしれません。"
      end

    rescue Net::OpenTimeout => e
      fetch_holidays(countrycode, year, retry_count - 1)

    rescue => e
      Rails.logger.error(e.class)
      Rails.logger.error(e.message)
      Rails.logger.error(e.backtrace.join("\n"))
      "入力値が正しくありません"
    end
  end
end
