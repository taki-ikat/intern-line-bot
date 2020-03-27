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
          # 一旦英数字以外があるかチェック→あったら"入力値が正しくありません"
          text = NKF.nkf('-w -Z1 -Z4', event.message['text'])     # 全角はスペース含めてすべて半角にする
          messages = []    # 返すメッセージ
          case text
          when /[^(-w, \s)]/    # 英数字とスペース以外を含んでいる場合
            messages << "半角英数字で入力してください。\n#{MESSAGE_HELP}"
          when /\Ahelp\z/i
            # 説明文を返す
            messages << "入力はすべて半角英数字でおこなってください。\n年を省略すると現在の年が適応されます。\n＜コマンド＞\n1. help\nこの説明が見られます。\n2. all\n対応する国名・国コードが確認できます。\n3. 年（数字4桁） 国コード（英字2字）または国名\n該当する祝日リストを返します。\n例1：2010 US\n例2：1964 Japan"
          when /\Aall\z/i
            # すべての国名・国コードを返す
            messages << generate_text_with_all_countries()
          else
            # 入力メッセージを国名候補と年に分割
            year, country = split_text_message(text)
            # 入力年が数字4桁か判定
            unless year =~ /\A#{YEAR}\z/
              messages << "入力年は数字4桁で入力してください。\n#{MESSAGE_HELP}"
            end
            countries = fetch_all_countries()     # なんらかのエラーが起きた場合，その旨を文字列で返す
            if countries.is_a?(String)
              messages << countries
            else
              # 国コードか判定
              countrycode = isCountryCode(country, countries)
              if countrycode.nil?
                messages << "入力した国名または国コードが正しくありません。\n#{MESSAGE_HELP}"
              else
                # 入力した国コードから祝日一覧を文字列で取得
                messages << fetch_holidays(countrycode, year)
              end
            end
          end
          # LINEの応答メッセージを生成して送信する
          client.reply_message(event['replyToken'], generate_message(messages))

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

  # 定数置き場
  MAX_RETRY_COUNT = 3
  API_URL = "https://date.nager.at/Api"
  YEAR = /([0-9]{4})/
  MESSAGE_HELP = "使い方の確認にはhelpと入力してください。"
  MESSAGE_TAKETIME = "時間をおいてみるとうまくいくかもしれません。"
  MESSAGE_TIMEOUT = "タイムアウトしました。\n#{MESSAGE_TAKETIME}"
  MESSAGE_NOTWORK = "調子が悪いみたいです。\n#{MESSAGE_TAKETIME}"

  def http_start(uri)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
      http.open_timeout = 5
      http.read_timeout = 10
      http.get(uri.request_uri)
    end
  end

  # 返すテキストメッセージの設定
  # Argument:
  #   messages: ["message1", "message2", ...]
  def generate_message(messages)
    messages.each_with_object([]) {|message, generated_messages|
      generated_messages << {
        type: 'text',
        text: message
      }
    }
  end

  # 引数が英字（＋スペース）のみで成り立っていたら"yyyy（現在の年）"と"そのまま"を返す
  # 引数が英数字とスペースのみで成り立っていたら"yyyy"と"Alphabets"に分割して返す
  def split_text_message(text)
    if text =~ /[0-9]/
      return text.split(/\s+/, 2)
    else
      return Time.zone.today.year.to_s, text
    end
  end

  # 返り値：国コード or nil
  def isCountryCode(country, countries)
    result = countries.find{|countryName, countryCode| countryCode =~ /\A#{country}\z/i || countryName =~ /\A#{country}\z/i}
    unless result.nil?
      return result[1]
    end
  end

  # すべての国名と国コードを改行タグでつないだ文字列で返す
  def generate_text_with_all_countries()
    fetch_all_countries().each_with_object(["国名:国コード"]){|country, countries_array|
      countries_array << "#{country[0]}:#{country[1]}"
    }.join("\n")
  end

  # すべての国名と国コードをhashで取得 {"countryName" => "countryCode", ...}
  # API接続でエラーが発生したらその旨を文字列で返す
  def fetch_all_countries(retry_count = MAX_RETRY_COUNT)
    return MESSAGE_TIMEOUT if retry_count <= 0
    begin
      uri = URI.parse("#{API_URL}/v2/AvailableCountries")
      response = http_start(uri)

      case response
      when Net::HTTPSuccess
        # すべての国名と国コードをhashで取得
        JSON.parse(response.body).map {|country| [country["value"], country["key"]]}.to_h
      else
        Rails.logger.error([uri.to_s, response].join(" : "))
        MESSAGE_NOTWORK
      end

    rescue Net::OpenTimeout => e
      fetch_all_countries(retry_count - 1)

    rescue => e
      Rails.logger.error(e.class)
      Rails.logger.error(e.message)
      Rails.logger.error(e.backtrace.join("\n"))
      MESSAGE_NOTWORK
    end
  end

  # 国コードと年に該当する祝日一覧を文字列で返す
  def fetch_holidays(countrycode, year, retry_count = MAX_RETRY_COUNT)
    return MESSAGE_TIMEOUT if retry_count <= 0

    begin
      uri = URI.parse("#{API_URL}/v1/Get/#{countrycode}/#{year}")
      response = http_start(uri)

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
        "#{countrycode}:存在しない国コードです"

      else
        Rails.logger.error([uri.to_s, response].join(" : "))
        MESSAGE_NOTWORK
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
