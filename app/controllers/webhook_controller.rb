require 'nkf'
require 'json'
require 'line/bot'

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
          countrycode, year = return_countrycode_year(event.message['text'])
          if countrycode.nil?
            message = "入力フォーマットが正しくありません"
          else
            # 入力した国コードから祝日一覧を文字列で取得
            message = fetch_holidays(countrycode, year)
          end
          # LINEの応答メッセージを生成して送信する
          client.reply_message(event['replyToken'], generate_message(message))

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

  # 入力フォーマットを判定し，国コードと年を返す
  def return_countrycode_year(text)
    case NKF.nkf('-w -Z1 -Z4', text)      # 全角はスペース含めてすべて半角にする
    when /([A-Za-z]{2})\s([0-9]{4})/      # フォーマット："国コード yyyy"
      countrycode, year = $1, $2
    when /([A-Za-z]{2})/                  # フォーマット："国コード"
      countrycode, year = $1, Time.zone.today.year
    else
      countrycode, year = nil, nil 
    end
  end

  # 国コードと年に該当する祝日一覧を文字列で返す
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
          case countrycode
          when /JP/i              # 日本なら日本語で返す
            country = "localName"
          else
            country = "name"      # それ以外は英語で返す
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
