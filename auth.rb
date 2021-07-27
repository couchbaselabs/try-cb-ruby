# frozen_string_literal: true

require 'jwt'

module Auth

  JWT_SECRET = "cbtravelsample"

  def genToken(username)
    # Generates a jwt token
    JWT.encode({ 'user' => username }, JWT_SECRET, algorithm = 'HS256')
  end

  def authenticated?(bearer_token, username)
    # Verifies the bearer token provided in the request header
    bearer = bearer_token.split(" ")[1]
    username == JWT.decode(bearer, JWT_SECRET, true)[0]['user']
  end

end
