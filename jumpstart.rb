require 'rubygems'
require 'aws'
require 'net/ssh'
require 'net/http'
require 'logger'

def message_lines
  2.times do |x|
    puts "****************************************"
  end
end

logger = Logger.new(STDOUT)


#load aws.yml -- This will allow you to login to aws
aws_conf = YAML.load(File.read('aws.yml'))

AWS.config(aws_conf)

instance = key_pair = group = nil

#create a new instance of the aws ec2 module
ec2 = AWS::EC2.new

#lookup the server ami. Is there a better way to do this?  
image = AWS.memoize do
   amazon_linux = ec2.images().
     filter("root-device-type", "instance-store").
     filter("name", "*ubuntu-images/ubuntu-natty-11.04-i386-server-20110426*")
   amazon_linux.to_a.sort_by(&:name).last
 end

logger.debug("Using AMI: #{image.id} --- #{image.name}")

#dynamically create a keypair for ec2 and save the private key to a file
key_pair = ec2.key_pairs.create("chef-kp-#{Time.now.to_i}")
logger.debug("Generated keypair #{key_pair.name}, fingerprint: #{key_pair.fingerprint}")
logger.debug("Writing #{key_pair.name} to identity.pem")
identity = File.new("identity.pem", "w")
identity.write(key_pair.private_key)
identity.close
File.chmod(0600,"identity.pem")

#create a security group for the chef server. Allow ssh and port 4000. 
group = ec2.security_groups.create("js-gp-#{Time.now.to_i}")
group.authorize_ingress(:tcp, 22, "0.0.0.0/0")  

logger.debug("Using security group: #{group.name}")

#start the Amazon ec2 instance
instance = image.run_instance(:key_pair => key_pair, :security_groups => group)
logger.info("Launched instance #{instance.id}, status: #{instance.status}")
sleep 2 until instance.status != :pending
logger.info("Launched instance #{instance.id}, status: #{instance.status}")
exit 1 unless instance.status == :running

#There is an race condition with port 22 being open, but no active SSHD. This sucks, but it's necessary. 
logger.debug("There seems to be a firewall rule lag here. Sleeping for 90 seconds.....")
sleep 90

#login to the machine with ssh and get chefs pre-installation rolling. 
logger.debug("Logging into IP: #{instance.ip_address}")

#Because of two interactive dialogs during the chef installation, I generate this script on the newly created server
# log you in, then run the script with an active screen. There may be a better way, but I know if you override these 
# dialogues, many important pieces of the chef configuration will not get generated. 

begin
  Net::SSH.start(instance.ip_address, "ubuntu", :key_data => [key_pair.private_key]) do |ssh|
    puts ssh.exec!("echo \"deb http://apt.opscode.com/ `lsb_release -cs`-0.10 main\" | sudo tee /etc/apt/sources.list.d/opscode.list")
    puts ssh.exec!("cat /etc/apt/sources.list.d/opscode.list")
    puts ssh.exec!("sudo mkdir -p /etc/apt/trusted.gpg.d")
    logger.debug("Configuring Keys for the Chef Apt Repository")
    puts ssh.exec!("sudo gpg --keyserver keys.gnupg.net --recv-keys 83EF826A")
    puts ssh.exec!("sudo gpg --export packages@opscode.com | sudo tee /etc/apt/trusted.gpg.d/opscode-keyring.gpg > /dev/null")
    logger.debug("Updating all of the sources on the ubuntu machine")
    puts ssh.exec!("sudo apt-get update")
    logger.debug("Installing Opscode Keyring")
    puts ssh.exec!("sudo DEBIAN_FRONTEND='noninteractive' apt-get install opscode-keyring --assume-yes")
    logger.debug("Installing XML Libraries for Nokogiri")
    puts ssh.exec!("sudo apt-get install libxslt1-dev libxml2-dev --assume-yes")
    logger.debug("Installing RubyGems")
    puts ssh.exec!("sudo apt-get install rubygems1.8 --assume-yes")
    logger.debug("Installing Git")
    puts ssh.exec!("sudo apt-get install git --assume-yes")
    logger.debug("Installing Merb-Haml")
    puts ssh.exec!("sudo gem install merb-haml --no-ri --no-rdoc")
    puts ssh.exec!("echo \"sudo apt-get install chef chef-server-api chef-expander --assume-yes\" > setup_chef")
    puts ssh.exec!("echo \"sudo gem install knife-ec2 --no-ri --no-rdoc \" >> setup_chef")
    puts ssh.exec!("echo \"rm .profile\" >> setup_chef")
    puts ssh.exec!("echo \"./setup_chef\" > .profile")
    puts ssh.exec!("echo \"#{key_pair.private_key}\" > identity.pem")
    puts ssh.exec!("chmod 755 setup_chef create_server")
    puts ssh.exec!("chmod 600 identity.pem")
  end
rescue SystemCallError, Timeout::Error => e
  logger.info("The ssh port may not be open, trying again")
  sleep 5
  retry
end 

login = File.new("login.sh", "w")
login.write("ssh -i identity.pem ubuntu@#{instance.ip_address}")
login.close
File.chmod(0755,"login.sh")

message_lines
puts "Automatically logging you into the new chef server to finish installation"
puts "Alternately you can use the command below:"
puts "ssh -i #{Dir.pwd}/identity.pem ubuntu@#{instance.ip_address}"
message_lines
sleep 5















