# step descriptions for MongoDB cartridge behavior.
require 'rubygems'
require 'mongo'
require 'fileutils'

Then /^the mongodb configuration file will( not)? exist$/ do |negate|
  cart = @gear.carts['mongodb-2.2']
  user_root = "#{$home_root}/#{@gear.uuid}/#{cart.name}"
  config_file = "#{user_root}/etc/mongodb.conf"

  begin
    cnffile = File.new config_file
  rescue Errno::ENOENT
    cnffile = nil
  end

  unless negate
    cnffile.should be_a(File)
  else
    cnffile.should be_nil
  end
end


Then /^the mongodb database will( not)? +exist$/ do |negate|
  cart = @gear.carts['mongodb-2.2']
  user_root = "#{$home_root}/#{@gear.uuid}/#{cart.name}"
  config_file = "#{user_root}/etc/mongodb.conf"
  data_dir = "#{user_root}/data/"

  begin
    datadir = Dir.new data_dir
  rescue Errno::ENOENT
    datadir = nil
  end

  unless negate
    datadir.should include "#{@app.name}.0"
    datadir.should include "#{@app.name}.ns"
    datadir.should include "mongod.lock"
    datadir.should include "admin.0"
    datadir.should include "admin.ns"
  else
    datadir.should be_nil
  end
end

Then /^the mongodb admin user will have access$/ do
  mongo_cart = @gear.carts['mongodb-2.2']

  begin
    dbh = Mongo::Connection.new(mongo_cart.db.ip.to_s).db(@app.name)
    dbh.authenticate(mongo_cart.db.username.to_s, mongo_cart.db.password.to_s)
  rescue Mongo::ConnectionError
    dbh = nil
  end

  dbh.should be_a(Mongo::DB)
  dbh.logout if dbh
end
