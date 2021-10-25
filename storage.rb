# frozen_string_literal: true

require 'yaml'
require 'couchbase'
require 'time'
require 'securerandom'

require_relative 'error'
require_relative 'auth'

include Couchbase

class Storage
  include Auth

  def initialize
    # load configuration
    host = ENV['CB_HOST'] || 'db'
    username = ENV['CB_USER'] || 'Administrator'
    password = ENV['CB_PSWD'] || 'password'

    # establish database connection
    options = Cluster::ClusterOptions.new
    options.authenticate(username, password)

    # If you don't want to log the database queries
    # set`show_queries` to false in the connection string below.
    @cluster = Cluster.connect("couchbase://#{host}?show_queries=true", options)
    @bucket = @cluster.bucket('travel-sample')
  end

  def get_airports(search_param)
    query_type = 'N1QL query - scoped to inventory: '

    query_prep = 'SELECT airportname FROM `travel-sample`.inventory.airport WHERE '

    same_case = search_param == search_param.downcase || search_param == search_param.upcase
    if same_case && search_param.length == 3
      query_prep += "faa=?"
      query_args = [search_param.upcase]
    elsif same_case && search_param.length == 4
      query_prep += "icao=?"
      query_args = [search_param.upcase]
    else
      query_prep += "POSITION(LOWER(airportname), ?) = 0"
      query_args = [search_param.downcase]
    end

    airport_list = []
    options = Cluster::QueryOptions.new
    options.positional_parameters(query_args)

    res = @cluster.query(query_prep, options)
    res.rows.each do |row|
      airport_list.push('airportname' => row['airportname'])
    end

    { 'context' => ["#{query_type} #{query_prep}"], 'data' => airport_list }
  end

  def get_flightpaths(from, to, leave)
    query_type = "N1QL query - scoped to inventory: "

    query_prep = 'SELECT faa as fromAirport FROM `travel-sample`.inventory.airport ' \
                 'WHERE airportname = $1 ' \
                 'UNION SELECT faa as toAirport FROM `travel-sample`.inventory.airport ' \
                 'WHERE airportname = $2'
    # add first query to context list
    context = ["#{query_type}\n #{query_prep}"]

    options = Cluster::QueryOptions.new
    options.positional_parameters([from, to])

    from_airport = ''
    to_airport = ''
    res = @cluster.query(query_prep, options)
    res.rows.each do |row|
      # Extract the 'fromAirport' and 'toAirport' values
      from_airport = row['fromAirport'] if row.key? 'fromAirport'
      to_airport = row['toAirport'] if row.key? 'toAirport'
    end

    query_routes = 'SELECT a.name, s.flight, s.utc, r.sourceairport, r.destinationairport, r.equipment ' \
                   'FROM `travel-sample`.inventory.route AS r ' \
                   'UNNEST r.schedule AS s ' \
                   'JOIN `travel-sample`.inventory.airline AS a ON KEYS r.airlineid ' \
                   'WHERE r.sourceairport = $from_faa AND r.destinationairport = $to_faa AND s.day = $day ' \
                   'ORDER BY a.name ASC '
    # add second query to context list
    context.push("#{query_type}\n #{query_routes}")

    options = Cluster::QueryOptions.new
    options.named_parameters({ 'from_faa' => from_airport, 'to_faa' => to_airport, 'day' => convdate(leave) })

    route_list = []
    res = @cluster.query(query_routes, options)
    res.rows.each do |row|
      row['flighttime'] = (rand() * 8000).ceil
      row['price'] = (row['flighttime'].to_f / 8 * 100 / 100).ceil(2)
      route_list.push(row)
    end

    { 'context' => context, 'data' => route_list }
  end

  def get_hotels(description, location)
    search = Cluster::SearchQuery
    search_cols = ['address', 'city', 'state', 'country', 'name', 'description']
    qp = search.conjuncts

    # Fallback in case we want to search for any hotels.
    # If this is not present, couchbase will error with `ArgumentError: compound conjunction query must have sub-queries`
    qp.and_also(search::TermQuery.new('hotel'))

    if location != "*" and location != ""
      qp.and_also(
        search.disjuncts(
          search.match_phrase(location) { |q| q.field = "country" },
          search.match_phrase(location) { |q| q.field = "city" },
          search.match_phrase(location) { |q| q.field = "state" },
          search.match_phrase(location) { |q| q.field = "address" },
        )
      )
    end

    if description != "*" and description != ""
      qp.and_also(
        search.disjuncts(
          search.match_phrase(description) { |q| q.field = "description" },
          search.match_phrase(description) { |q| q.field = "name" },
        )
      )
    end

    scope = @bucket.scope('inventory')
    context = "FTS search - scoped to: #{scope.name}.hotel within fields #{search_cols.join(',')}"

    res = @cluster.search_query("hotels-index", qp, Options::Search(limit: 100))
    data = extract_hotel_search_results(res, scope, search_cols)

    { 'context' => [context], 'data' => data }
  end

  def get_user(user, password, agent)
    agent_scope = @bucket.scope(agent)
    users_collection = agent_scope.collection('users')

    begin
      doc_pass = users_collection.lookup_in(user, [LookupInSpec.get("password")]).content(0)
      raise PasswordMismatchError.new if doc_pass != password
    rescue Error::DocumentNotFound => e
      raise UserNotFoundError.new
    else
      context = "KV get - scoped to #{agent_scope.name}.users: for password field in document #{user}"
      return { 'context' => [context], 'data' => { 'token' => genToken(user) } }
    end
  end

  def save_user(user, password, agent)
    agent_scope = @bucket.scope(agent)
    users_collection = agent_scope.collection('users')

    begin
      users_collection.insert(user, { 'username' => user, 'password' => password })
    rescue Error::DocumentExists => e
      raise UserAlreadyExistsError.new
    else
      context = "KV insert - scoped to #{agent_scope.name}.users: document #{user}"
      return { 'context' => [context], 'data' => { 'token' => genToken(user) } }
    end
  end

  def get_user_flights(user, agent, bearer_token)
    agent_scope = @bucket.scope(agent)
    users_collection = agent_scope.collection('users')
    flights_collection = agent_scope.collection('bookings')

    raise InvalidUserTokenError.new unless authenticated?(bearer_token, user)

    begin
      bookings = users_collection.lookup_in(user, [LookupInSpec.get("bookings")])
      
      rows = []
      if bookings.exists?(0)
        booked_flights = bookings.content(0)

        booked_flights.each do |flight|
          rows.push(flights_collection.get(flight).content)
        end
      end
    rescue Error::DocumentNotFound => e
      raise UserNotFoundError.new
    else
      context = "KV get - scoped to #{agent_scope.name}.users: for #{rows.length} bookings in document #{user}"
      return { 'context' => [context], 'data' => rows }
    end
  end

  def update_user_flights(user, agent, bearer_token, flights)
    agent_scope = @bucket.scope(agent)
    users_collection = agent_scope.collection('users')
    flights_collection = agent_scope.collection('bookings')

    raise InvalidUserTokenError.new unless authenticated?(bearer_token, user)

    begin
      new_flight = flights[0]
      flight_id = uuid = SecureRandom.uuid
      flights_collection.upsert(flight_id, new_flight)

      users_collection.mutate_in(user, [
        MutateInSpec.array_append('bookings', [flight_id]).create_path
      ])
    rescue Error::DocumentNotFound => e
      raise UserNotFoundError.new
    else
      context = "KV update - scoped to #{agent_scope.name}.users: for bookings field in document #{user}"
      return { 'context' => [context], 'data' => { 'added' => [new_flight] } }
    end
  end

  private

  def convdate(rawdate)
    # Returns integer data from mm/dd/YYYY
    Time.strptime(rawdate, '%m/%d/%Y').wday
  end

  def extract_hotel_search_results(result, scope, search_cols)
    extracted_results = []

    hotel_collection = scope.collection('hotel')

    result.rows.each do |row|
      spec_array = []
      search_cols.each { |c| spec_array << LookupInSpec.get(c) }
      subdoc = hotel_collection.lookup_in(row.id, spec_array)

      subresults = {}
      # Get the address fields from the document, if they exist
      address_values = []
      search_cols[0..3].each_index { |i| address_values << subdoc.content(i) if subdoc.content(i) != nil }
      address = address_values.join(', ')
      subresults['address'] = address

      # Get the hotel name and description fields from the document, if they exist
      search_cols[4, 5].each do
        subresults['description'] = subdoc.content(5) if subdoc.content(5) != nil
        subresults['name'] = subdoc.content(4) if subdoc.content(4) != nil
      end

      extracted_results.push(subresults)
    end

    extracted_results
  end

end
