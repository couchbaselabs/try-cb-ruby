# frozen_string_literal: true

require 'sinatra'
require 'sinatra/namespace'
require 'sinatra/cors'
require 'json'

require_relative 'storage'

storage = Storage.new

set :allow_origin, "*"
set :allow_methods, "GET,HEAD,POST,PUT,DELETE,OPTIONS"
set :allow_headers, "Access-Control-Allow-Origin, origin, x-requested-with, content-type, accept, authorization"
set :allow_credentials, "true"

get '/' do
  'Hello World'
end

namespace '/api' do

  before do
    content_type 'application/json'
    @request_headers = request.env
  end

  after do
    response.body = JSON.dump(response.body)
  end

  get '/airports' do
    status 200
    storage.get_airports(params[:search])
  end

  get '/flightPaths/:from_loc/:to_loc' do
    from = params[:from_loc]
    to = params[:to_loc]
    leave = params[:leave]

    status 200
    storage.get_flightpaths(from, to, leave)
  end

  get '/hotels/:description/:location/' do
    description = params[:description]
    location = params[:location]

    status 200
    storage.get_hotels(description, location)
  end

  namespace '/tenants' do

    post '/:tenant/user/login' do
      req = JSON.parse(request.body.read)
      agent = params[:tenant].downcase
      user = req['user'].downcase
      password = req['password']

      begin
        result = storage.get_user(user, password, agent)
      rescue PasswordMismatchError => e
        abort_msg(401, e.message)
      rescue UserNotFoundError => e
        abort_msg(401, e.message)
      else
        status 200
        result
      end
    end

    post '/:tenant/user/signup' do
      req = JSON.parse(request.body.read)
      agent = params[:tenant].downcase
      user = req['user'].downcase
      password = req['password']

      begin
        result = storage.save_user(user, password, agent)
      rescue UserAlreadyExistsError => e
        abort_msg(409, e.message)
      else
        status 201
        result
      end
    end

    get '/:tenant/user/:username/flights' do
      agent = params[:tenant].downcase
      user = params[:username].downcase
      bearer_token = @request_headers['HTTP_AUTHORIZATION']

      return abort_msg(401, 'No token provided') if bearer_token == nil

      begin
        result = storage.get_user_flights(user, agent, bearer_token)
      rescue InvalidUserTokenError => e
        abort_msg(401, e.message)
      rescue UserNotFoundError => e
        abort_msg(401, e.message)
      else
        status 200
        result
      end
    end

    put '/:tenant/user/:username/flights' do
      req = JSON.parse(request.body.read)
      agent = params[:tenant].downcase
      user = params[:username].downcase
      bearer_token = @request_headers['HTTP_AUTHORIZATION']
      flights = req['flights']

      begin
        result = storage.update_user_flights(user, agent, bearer_token, flights)
      rescue InvalidUserTokenError => e
        abort_msg(401, e.message)
      rescue UserNotFoundError => e
        abort_msg(401, e.message)
      else
        status 200
        result
      end
    end

  end

end

def abort_msg(error_code, message)
  status error_code
  body 'message' => message
end
