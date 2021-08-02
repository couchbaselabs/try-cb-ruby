# frozen_string_literal: true

class PasswordMismatchError < StandardError
  def initialize(msg = "Password does not match")
    super
  end
end

class UserAlreadyExistsError < StandardError
  def initialize(msg = "User already exists")
    super
  end
end

class InvalidUserTokenError < StandardError
  def initialize(msg = "Username does not match token username")
    super
  end
end

class UserNotFoundError < StandardError
  def initialize(msg = "User does not exist")
    super
  end
end
