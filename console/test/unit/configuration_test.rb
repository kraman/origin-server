require File.expand_path('../../test_helper', __FILE__)

#
# Mock tests only - should verify functionality of ActiveResource extensions
# and simple server/client interactions via HttpMock
#
class ConfigurationTest < ActiveSupport::TestCase
  setup do 
    @old_config = Console.instance_variable_get(:@config)
    Console.instance_variable_set(:@config, nil)
  end
  teardown{ Console.instance_variable_set(:@config, @old_config) }

  def expects_file_read(contents, file='file')
    IO.expects(:read).with(File.expand_path(file)).returns(contents)
  end

  test 'ConfigFile handles key pairs' do
    expects_file_read(<<-FILE.strip_heredoc)
      key=1
      escaped\\==2
      double_escaped\\\\=3
      escaped_value=\\4
        spaces = 5
      #comment=6

      commented_value=7 # some comments
      comm#ented_key=8
      greedy=equals=9
    FILE
    c = Console::ConfigFile.new('file')
    assert_equal({
      'key' => '1',
      'escaped=' => '2',
      'double_escaped\\' => '3',
      'escaped_value' => '4',
      'spaces' => '5',
      'commented_value' => '7',
      'greedy' => 'equals=9',
    }, c)
  end

  test 'Console.configure yields' do
    Console.configure{ @ran = true }
    assert @ran
  end

  test 'Console.configure reads file' do
    expects_file_read(<<-FILE.strip_heredoc)
      broker_url=foo
      broker_api_user=bob
    FILE
    Console.configure('file')
    assert_equal 'foo', Console.config.api[:url]
    assert_equal 'bob', Console.config.api[:user]
    assert_equal 'file', Console.config.api[:source]
    assert_nil Console.config.security_controller # base config object has no defaults
  end

  test 'Console.configure raises IO errors' do
    IO.expects(:read).with(File.expand_path('file')).raises(Errno::ENOENT)
    assert_raise(Errno::ENOENT){ Console.configure('file') }
  end

  test 'Console.configure raises InvalidConfiguration' do
    expects_file_read(<<-FILE.strip_heredoc)
    FILE
    assert_raise(Console::InvalidConfiguration){ Console.configure('file') }
  end

  test 'Console.configure sets security_controller from basic' do
    expects_file_read(<<-FILE.strip_heredoc)
      broker_url=foo
      console_security=basic
    FILE
    Console.configure('file')
    assert_equal Console::Auth::Basic, Console.config.security_controller.constantize
  end

  test 'Console.configure sets security_controller from passthrough' do
    expects_file_read(<<-FILE.strip_heredoc)
      broker_url=foo
      console_security=passthrough
    FILE
    Console.configure('file')
    assert_equal Console::Auth::Passthrough, Console.config.security_controller.constantize
  end

  test 'Console.configure sets security_controller to arbitrary' do
    expects_file_read(<<-FILE.strip_heredoc)
      broker_url=foo
      console_security=Console::Auth::None
    FILE
    Console.configure('file')
    assert_equal Console::Auth::None, Console.config.security_controller.constantize
  end

  test 'Console.config.api sets api :external' do
    expects_file_read(<<-FILE.strip_heredoc, '~/.openshift/console.conf')
      broker_url=foo
      broker_api_source=ignored
      broker_api_user=bob
      broker_api_symbol=:foo
      broker_api_timeout=0
      broker_api_ssl_options={:verify_mode => OpenSSL::SSL::VERIFY_NONE}
      broker_proxy_url=proxy
      console_security=Console::Auth::None
    FILE
    (config = Console::Configuration.new).api = :external
    assert_equal 'foo', config.api[:url]
    assert_equal 'proxy', config.api[:proxy]
    assert_equal 'bob', config.api[:user]
    assert_equal :foo, config.api[:symbol]
    assert_equal 0, config.api[:timeout]
    assert_equal '~/.openshift/console.conf', config.api[:source]
    assert_equal({'verify_mode' => OpenSSL::SSL::VERIFY_NONE}, config.api[:ssl_options])
    assert_equal OpenSSL::SSL::VERIFY_NONE, config.api[:ssl_options][:verify_mode]
    assert_nil config.security_controller # is ignored
  end

  test 'Console.config.api accepts :local' do
    (config = Console::Configuration.new).api = :local
    assert_equal 'https://localhost/broker/rest', config.api[:url]
    assert_equal :local, config.api[:source]
    assert_nil config.security_controller # is ignored
  end

  test 'Console.config.api accepts valid object' do
    (config = Console::Configuration.new).api = {:url => 'foo', :user => 'bob'}
    assert_equal 'foo', config.api[:url]
    assert_equal 'bob', config.api[:user]
    assert_equal 'object in config', config.api[:source]
    assert_nil config.security_controller # is ignored
  end

  test 'Console.config.api raises on invalid object' do
    assert_raise(Console::InvalidConfiguration){ Console::Configuration.new.api = {:url => nil, :user => 'bob'} }
  end

  test 'Console.config.api raises on unrecognized option' do
    assert_raise(Console::InvalidConfiguration){ Console::Configuration.new.api = nil }
  end
end

