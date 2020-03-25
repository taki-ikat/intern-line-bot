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
          client.reply_message(event['replyToken'], set_message(get_holidays(event.message['text'], '2020')))
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

  # 返すテキストメッセージの設定
  # レベル3でおそらく複数回使用するので残しています
  def set_message(text)
    {
      type: 'text',
      text: text
    }
  end

  # 国コードと年に該当する祝日リストを返す
  def get_holidays(countrycode, year, retry_count = 10)
    raise ArgumentError, 'too many HTTP redirects' if retry_count == 0

    begin
      uri = URI.parse("https://date.nager.at/Api/v1/Get/#{countrycode}/#{year}")
      holidays_list = ""    # returnする祝日リスト（改行タグで区切られた文字列）
  
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
          holidays.each { |holiday|
            holidays_list << "#{holiday["date"]}:#{holiday[country]}\n"
          }
          holidays_list.chomp!        # 最後の改行タグ削除
          return holidays_list

        when Net::HTTPRedirection
          location = response['location']
          Rails.logger.error(warn "redirected to #{location}")
          get_holidays(countrycode, year, retry_count - 1)

        else
          Rails.logger.error([uri.to_s, response.value].join(" : "))
          "HTTP接続エラーです。\nお手数ですが、運営元にお問い合わせください。"
      end

    rescue => e
      Rails.logger.error(e.class)
      Rails.logger.error(e.message)
      "入力値が正しくありません"
    end
  end
end
