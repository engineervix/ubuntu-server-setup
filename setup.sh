#!/bin/bash

set -e

function getCurrentDir() {
    local current_dir="${BASH_SOURCE%/*}"
    if [[ ! -d "${current_dir}" ]]; then current_dir="$PWD"; fi
    echo "${current_dir}"
}

function includeDependencies() {
    # shellcheck source=./setupLibrary.sh
    source "${current_dir}/setupLibrary.sh"
}

current_dir=$(getCurrentDir)
includeDependencies
output_file="output.log"

function main() {
  read -rp "Enter the username of the new user account:" username

  echo "Please specify your Git Global Name & Email" 
  read -rp 'Your (git) Name: ' git_name 
  read -rp 'Your (git) Email Address: ' git_email 

  promptForPassword

  # Run setup functions
  trap cleanup EXIT SIGHUP SIGINT SIGTERM

  addUserAccount "${username}" "${password}"

  read -rp $'Paste in the public SSH key for the new user:\nHint: cat ~/.ssh/id_rsa.pub\n' sshKey
  echo 'Running setup script...'
  logTimestamp "${output_file}"

  # Use exec and tee to redirect logs to stdout and a log file at the same time 
  # https://unix.stackexchange.com/a/145654
  exec > >(tee -a "${output_file}") 2>&1
  disableSudoPassword "${username}"
  addSSHKey "${username}" "${sshKey}"
  changeSSHConfig
  extraHardening
  setupUfw

  if ! hasSwap; then
      setupSwap
  fi

  setupTimezone

  # echo "Installing Network Time Protocol... " 
  configureNTP

  # setupHostname
  setupNodeYarn

  sudo -i -u "${username}" -H bash -c "mkdir -p /home/${username}/bin"

  setupGit
  setupZSH
  setupRuby
  setupPythonDev
  setupVim
  setupDatabases
  setupWebServer
  setupMail
  configureSystemUpdatesAndLogs
  furtherHardening
  miscellaneousTasks
  installExtraPackages

  # fix for (warning: unable to access '$HOME/.config/git/attributes': Permission denied)
  sudo -i -u "${username}" -H bash -c "mkdir -p /home/${username}/.config"
  sudo chown -R "${username}" /home/"${username}"/.config/

  sudo service ssh restart

  cleanup

  echo -e "\e[35mYou have installed ZSH $(zsh --version)\e[00m" 
  echo -e "\e[35mLet us now make ZSH your default shell ...\e[00m" 
  sudo -i -u "${username}" -H bash -c "chsh -s $(which zsh)"

  sudo mv -v "${current_dir}/${output_file}" /home/"${username}"/ && sudo chown -R "${username}":"${username}" /home/"${username}"/"${output_file}"
  sudo rm -fv /home/"${username}"/oh_my_zsh_install.sh
  echo -e "Setup Done! Log file (\e[35m${output_file}\e[00m) is in \e[35m${username}\e[00m's home directory"
}

function logTimestamp() {
  local filename=${1}
  {
    echo "===================" 
    echo "Log generated on $(date)"
    echo "==================="
  } >>"${filename}" 2>&1
}

function setupTimezone() {
  echo -ne "Enter the timezone for the server (Default is 'Africa/Lusaka'):\n" 
  read -r timezone
  if [ -z "${timezone}" ]; then
    timezone="Africa/Lusaka"
  fi
  setTimezone "${timezone}"
  echo "Timezone is set to $(cat /etc/timezone)" 
}

function hasSwap() {
  [[ "$(sudo swapon -s)" == *"/swapfile"* ]]
}

function setupSwap() {
  createSwap
  mountSwap
  tweakSwapSettings "10" "50"
  saveSwapSettings "10" "50"
}

function cleanup() {
  if [[ -f "/etc/sudoers.bak" ]]; then
    revertSudoers
  fi
}

# Keep prompting for the password and password confirmation
function promptForPassword() {
  PASSWORDS_MATCH=0
  while [ "${PASSWORDS_MATCH}" -eq "0" ]; do
    read -s -rp "Enter new UNIX password:" password
    printf "\n"
    read -s -rp "Retype new UNIX password:" password_confirmation
    printf "\n"

    if [[ "${password}" != "${password_confirmation}" ]]; then
      echo "Passwords do not match! Please try again."
    else
      PASSWORDS_MATCH=1
    fi
  done 
}

# ----------- addtitional functions not in original script ----------- #

function extraHardening() {
  # restrict access to the server
  echo "AllowUsers ${username}" | sudo tee -a /etc/ssh/sshd_config

  # Secure Shared Memory
  # tip 6 at https://hostadvice.com/how-to/how-to-harden-your-ubuntu-18-04-server/
  echo "none /run/shm tmpfs defaults,ro 0 0" | sudo tee -a /etc/fstab
}

function setupHostname() {
  # hostname 
  # this hostname should have a DNS A record pointing to the IP address of your server.
  # ref: https://linuxize.com/post/how-to-change-hostname-on-ubuntu-18-04/
  # ref: https://aws.amazon.com/premiumsupport/knowledge-center/linux-static-hostname/
  hostnamectl
  echo "Let's setup a new hostname" 
  read -rp 'hostname: ' myhostname 
  sudo hostnamectl set-hostname "$myhostname"

  cat /etc/hosts
  echo "updating your /etc/hosts file" 
  # add text after 1st line
  # https://stackoverflow.com/a/44894788
  sudo sed -i "1 a 127.0.0.1   $myhostname" /etc/hosts

  # for AWS ...
  echo -e "\e[35m===========================================================\e[00m" 
  echo -e "changing \e[35mpreserve_hostname: false\e[00m to \e[35mpreserve_hostname: true\e[00m" 
  echo -e "\e[35m===========================================================\e[00m" 
  sudo sed -i -e 's/preserve_hostname:\ false/preserve_hostname:\ true/g' /etc/cloud/cloud.cfg
}

function setupNodeYarn() {
  # nodeJS
  curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
  sudo apt-get install -y nodejs

  # yarn
  curl -sL https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
  echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
  sudo apt-get update && sudo apt-get install yarn

  # let's install some important global node packages
  sudo npm install -g browser-sync
  sudo npm install -g caniuse-cmd
  sudo npm install -g commitizen
  sudo npm install -g concurrently
  sudo npm install -g doctoc
  sudo npm install -g html-minifier
  sudo npm install -g grunt-cli
  sudo npm install -g gulp-cli
  sudo npm install -g lite-server
  sudo npm install -g local-cors-proxy
  sudo npm install -g maildev
  sudo npm install -g mdpdf --unsafe-perm=true --allow-root
  sudo npm install -g mozjpeg --unsafe-perm=true --allow-root
  sudo npm install -g prettier
  sudo npm install -g sass
  sudo npm install -g semantic-release-cli
  sudo npm install -g serve
  sudo npm install -g svgo
  sudo npm install -g uglify-js
}

function setupGit() {
  # Configure git
  execAsUser "${username}" "git config --global color.ui true"

  execAsUser "${username}" "git config --global user.name \"${git_name}\""
  execAsUser "${username}" "git config --global user.email \"${git_email}\""
}

function setupZSH() {
  sudo apt-get install zsh -y

  # ohmyzsh
  sudo wget https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -O /home/"$username"/oh_my_zsh_install.sh
  sudo -i -u "${username}" -H bash -c "ZSH=\"/home/$username/.oh-my-zsh\" sh oh_my_zsh_install.sh --unattended"
  sudo chown -R "${username}":"${username}" /home/"${username}"/.oh-my-zsh
  sudo cp -v "${current_dir}"/.zshrc /home/"$username"/ && sudo chown -R "${username}":"${username}" /home/"$username"/.zshrc
  sudo -i -u "${username}" -H bash -c "sed -i \"s/root/home\/$username/g\" /home/$username/.zshrc"
  # powerlevel10k
  sudo -i -u "${username}" -H bash -c "git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ${ZSH_CUSTOM:-/home/$username/.oh-my-zsh/custom}/themes/powerlevel10k"
  # Replace ZSH_THEME="robbyrussell" with ZSH_THEME="powerlevel10k/powerlevel10k".
  sudo -i -u "${username}" -H bash -c "sed 's/robbyrussell/powerlevel10k\/powerlevel10k/g' -i /home/$username/.zshrc"

  # font installation
  sudo apt install fonts-inconsolata fonts-symbola -y
  sudo apt install fonts-powerline -y

  wget https://github.com/Lokaltog/powerline/raw/develop/font/PowerlineSymbols.otf https://github.com/Lokaltog/powerline/raw/develop/font/10-powerline-symbols.conf
  wget https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Regular.ttf
  wget https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold.ttf
  wget https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Italic.ttf
  wget https://github.com/romkatv/powerlevel10k-media/raw/master/MesloLGS%20NF%20Bold%20Italic.ttf

  sudo mv -v PowerlineSymbols.otf /usr/share/fonts/
  sudo mv -v MesloLGS*.ttf /usr/share/fonts/

  sudo fc-cache -vf

  sudo mv 10-powerline-symbols.conf /etc/fonts/conf.d/

  echo -e "\e[35min order to use your fancy new ZSH setup, you'll have to later exit terminal and enter a new session\e[00m" 
}

function setupRuby() {
  sudo apt-get install ruby-full ruby-bundler -y
}

function setupPythonDev() {
  # some essentials (based on https://github.com/pyenv/pyenv/wiki#suggested-build-environment)
  sudo apt-get install --no-install-recommends make build-essential libssl-dev libbz2-dev libreadline-dev libsqlite3-dev llvm libncurses5-dev xz-utils libxml2-dev libxmlsec1-dev liblzma-dev -y

  sudo apt-get install -y python3-pip  # also installs python3-dev

  # PILLOW needs these
  sudo apt-get install -y libffi-dev libjpeg-dev zlib1g-dev libtiff-dev libfreetype6-dev libraqm-dev libraqm0 pngquant libopenjp2-7-dev libopenjp2-7 tk-dev libwebp-dev liblcms2-dev

  # virtualenvwrapper
  sudo -H pip3 install virtualenvwrapper
  export WORKON_HOME=/home/$username/Env
  sudo mkdir -p "$WORKON_HOME" && sudo chown -R "${username}":"${username}" /home/"${username}"/Env/

  sudo -i -u "${username}" -H bash -c "echo \"\" >> /home/$username/.zshrc"
  sudo -i -u "${username}" -H bash -c "echo \"# virtualenvwrapper\" >> /home/$username/.zshrc"
  sudo -i -u "${username}" -H bash -c "echo \"export WORKON_HOME=~/Env\" >> /home/$username/.zshrc"
  sudo -i -u "${username}" -H bash -c "echo \"export VIRTUALENVWRAPPER_PYTHON=/usr/bin/python3\" >> /home/$username/.zshrc"
  sudo -i -u "${username}" -H bash -c "echo \"source /usr/local/bin/virtualenvwrapper.sh\" >> /home/$username/.zshrc"
  sudo -i -u "${username}" -H bash -c "echo \"\" >> /home/$username/.zshrc"

  # Install pyenv <https://github.com/pyenv/pyenv>
  # sudo -i -u "${username}" -H bash -c "curl https://pyenv.run | bash"

  # uwsgi
  sudo -H pip3 install uWSGI
  sudo mkdir -p /etc/uwsgi/sites
  sudo cp -v configuration_files/uwsgi.service /etc/systemd/system/uwsgi.service
  sudo sed -i "s/CHANGE_THIS_TO_USERNAME/${username}/g" /etc/systemd/system/uwsgi.service
  sudo systemctl start uwsgi
  sudo systemctl enable uwsgi

  # celery
  sudo useradd celery -d /home/celery -b /bin/bash
  sudo mkhomedir_helper celery

  sudo mkdir /var/log/celery
  sudo chown -R celery:celery /var/log/celery
  sudo chmod -R 755 /var/log/celery

  sudo mkdir /var/run/celery
  sudo chown -R celery:celery /var/run/celery
  sudo chmod -R 755 /var/run/celery

}

function setupVim() {
  # Vim setup
  sudo -u "${username}" -H bash -c "sudo -H pip3 install powerline-status"
  sudo apt-get install vim-nox -y
  sudo -u "${username}" -H bash -c "curl -L https://gist.githubusercontent.com/engineervix/d9cef5adb520b6c2f2ee0e01e5280f1e/raw/8730b81fb4b18eb4476976520de9672d3335eaee/janus_setup.sh | bash"
  pushd "$HOME"/ubuntu-server-setup/
  sudo cp -rv "$HOME"/ubuntu-server-setup/.janus/ /home/"${username}"/ && sudo chown -R "${username}":"${username}" /home/"${username}"/.janus/
  sudo cp -v "$HOME"/ubuntu-server-setup/.vimrc.after /home/"${username}"/ && sudo chown -R "${username}":"${username}" /home/"${username}"/.vimrc.after
}

function setupDatabases() {
  # postgres
  sudo apt install postgresql postgresql-contrib postgis libpq-dev -y
  # Note this when dealing with older versions of Django (pre 1.11.x)
  # https://stackoverflow.com/questions/18643998/geodjango-geosexception-error
  sudo -Hiu postgres createuser --interactive
  sudo -Hiu postgres createdb "${username}"
  # take note of http://initd.org/psycopg/docs/install.html#prerequisites

  echo "DB_HOST:DB_PORT:DB_NAME:DB_USER:DB_PASSWORD" | tee -a /home/"${username}"/.pgpass
  echo "ANOTHER_DB_HOST:ANOTHER_DB_PORT:ANOTHER_DB_NAME:ANOTHER_DB_USER:ANOTHER_DB_PASSWORD" | tee -a /home/"${username}"/.pgpass
  chmod 600 /home/"${username}"/.pgpass
  chown "${username}":"${username}" /home/"${username}"/.pgpass

  # redis (https://www.digitalocean.com/community/tutorials/how-to-install-and-secure-redis-on-ubuntu-18-04)
  sudo apt install redis-server -y
  echo "The supervised directive is set to 'no' by default. "
  echo "Since you are running Ubuntu, which uses the systemd init system, I will change this to 'systemd' ..."
  sudo sed 's/^supervised\ no/supervised\ systemd/' -i /etc/redis/redis.conf
  sudo systemctl restart redis.service

}

function setupWebServer() {
  # nginx
  sudo apt install nginx -y
  sudo ufw allow 'Nginx Full'
  sudo ufw status

  sudo rm -v /etc/nginx/sites-enabled/default

  sudo nginx -t
  sudo systemctl enable nginx

  # copy some configurations
  sudo cp -v configuration_files/nginx/ssl.conf /etc/nginx/snippets/
  sudo cp -v configuration_files/nginx/letsencrypt.conf /etc/nginx/snippets/

  sudo chown root:root /etc/nginx/snippets/ssl.conf
  sudo chown root:root /etc/nginx/snippets/letsencrypt.conf

  # certbot (letsencrypt support)
  # sudo -H pip3 install certbot certbot-nginx certbot-dns-cloudflare
  sudo snap install core
  sudo snap refresh core
  sudo snap install --classic certbot
  sudo ln -s /snap/bin/certbot /usr/bin/certbot
  sudo snap set certbot trust-plugin-with-root=ok
  sudo snap install certbot-dns-cloudflare

  sudo mkdir -p /var/www/letsencrypt/.well-known/

  # Cloudflare's Authenticated Origin Pulls feature. See
  # - https://developers.cloudflare.com/ssl/origin-configuration/authenticated-origin-pull
  # - https://community.cloudflare.com/t/authenticated-origin-pulls-feature/137285/15
  sudo mkdir -p /etc/letsencrypt/cloudflare/
  sudo wget https://support.cloudflare.com/hc/en-us/article_attachments/360044928032/origin-pull-ca.pem -O /etc/letsencrypt/cloudflare/origin-pull-ca.pem

  echo "#!/bin/bash" | sudo tee /root/letsencrypt.sh
  echo "systemctl reload nginx" | sudo tee -a /root/letsencrypt.sh
  echo "" | sudo tee -a /root/letsencrypt.sh
  echo "# If you have other services that use the certificates:" | sudo tee -a /root/letsencrypt.sh
  echo "# systemctl restart mosquitto" | sudo tee -a /root/letsencrypt.sh

  # crontab
  systemctl enable --now cron
  crontab -l | { cat; echo "40 3 * * * certbot renew --noninteractive --renew-hook /root/letsencrypt.sh"; } | crontab -

  # openSSL
  sudo openssl dhparam -out /etc/letsencrypt/dhparam.pem 4096

}

function setupMail() {

  read -rp 'email address for root (dest email)?: ' root_email 
  read -rp 'email address for sending mail (from email)?: ' mail_from 
  sendgrid_domain=${mail_from#*@*}
  system_hostname=$(hostname)

  sudo debconf-set-selections <<< "postfix postfix/mailname string ${sendgrid_domain}"
  sudo debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"

  # Install Postfix
  sudo apt-get install libsasl2-modules postfix -y
  sudo apt install mailutils -y

  # Install mutt
  sudo apt install mutt -y

  # First, let's deal with /etc/postfix/main.cf
  sudo mv -v /etc/postfix/main.cf /etc/postfix/main.cf.bak
  sudo cp -v configuration_files/postfix_main.cf /etc/postfix/main.cf
  sudo sed -i "s/CHANGE_THIS_TO_HOSTNAME/${system_hostname}/g" /etc/postfix/main.cf
  sudo sed -i "s/CHANGETHIS_TO_SENDGRID_DOMAIN/${sendgrid_domain}/g" /etc/postfix/main.cf

  # /etc/mailname already has ${sendgrid_domain}, so we don't mess with it

  # Now, we deal with /etc/postfix/sasl_passwd
  echo -e "\e[35m===========================================================\e[00m" 
  echo -e "\e[35m Please provide your Sendgrip API key for Postfix to use. \e[00m" 
  echo -e "\e[35m NOTE: It will not be displayed in the terminal when you type / paste it in\e[00m" 
  read -s -p 'Sendgrid API key?: ' sendgrid_api_key
  echo "[smtp.sendgrid.net]:587 apikey:${sendgrid_api_key}" | sudo dd of=/etc/postfix/sasl_passwd
  echo -e "\e[35m===========================================================\e[00m" 

  sudo postmap hash:/etc/postfix/sasl_passwd
  sudo chown root:root /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db
  sudo chmod 0600 /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db

  # aliases
  echo "" | sudo tee -a /etc/aliases
  echo "root: ${root_email}" | sudo tee -a /etc/aliases
  sudo newaliases

  # canonical_maps
  echo "/.+/    ${mail_from}" | sudo tee /etc/postfix/sender_canonical_maps

  # header_check
  echo "/From:.*/ REPLACE From: ${mail_from}" | sudo tee /etc/postfix/header_check

  # reload postfix
  sudo postfix reload
}

function configureSystemUpdatesAndLogs() {
  # Updates notification and other necessary sysadmin stuff

  # https://help.ubuntu.com/lts/serverguide/automatic-updates.html.en
  # https://linuxize.com/post/how-to-set-up-automatic-updates-on-ubuntu-18-04/
  sudo apt install apticron -y
  echo -e "\e[35m===========================================================\e[00m"
  echo "copying the \e[35mconfiguration_files/apticron.conf\e[00m file to \e[35m/etc/apticron/apticron.conf\e[00m ..."
  sudo cp -v configuration_files/apticron.conf /etc/apticron/apticron.conf
  echo "to be notified (via email) of any impending updates, I'll update \e[35mEMAIL=\e[00m ..."
  sudo sed -i "s/^EMAIL=\"\"/EMAIL=\"$root_email\"/" /etc/apticron/apticron.conf
  echo -e "\e[35m===========================================================\e[00m"
  sudo apt install apt-show-versions -y
  sudo dpkg-reconfigure -plow unattended-upgrades
  echo -e "\e[35m===========================================================\e[00m"
  echo "I am now configuring the Unattended Upgrades package ..."
  #   sudo vim /etc/apt/apt.conf.d/50unattended-upgrades
  # 1. Unattended-Upgrade::DevRelease "auto"                        » Unattended-Upgrade::DevRelease\ "false"
  # 2. //Unattended-Upgrade::Mail ""                                » Unattended-Upgrade::Mail\ "$root_email"
  # 3. //Unattended-Upgrade::Remove-Unused-Kernel-Packages\ "true"  » Unattended-Upgrade::Remove-Unused-Kernel-Packages\ "true"
  # 4. //Unattended-Upgrade::Remove-New-Unused-Dependencies\ "true" » Unattended-Upgrade::Remove-New-Unused-Dependencies\ "true"
  # 5. //Unattended-Upgrade::Automatic-Reboot\ "false"              » Unattended-Upgrade::Automatic-Reboot\ "true"
  # 6. //Unattended-Upgrade::Automatic-Reboot-Time\ "02:00"         » Unattended-Upgrade::Automatic-Reboot-Time\ "02:17"
  sudo sed -i 's/^Unattended-Upgrade::DevRelease\ "auto"/Unattended-Upgrade::DevRelease\ "false"/' /etc/apt/apt.conf.d/50unattended-upgrades
  sudo sed -i "s#^//Unattended-Upgrade::Mail\ \"\"#Unattended-Upgrade::Mail\ \"$root_email\"#" /etc/apt/apt.conf.d/50unattended-upgrades
  sudo sed -i 's#^//Unattended-Upgrade::Remove-Unused-Kernel-Packages\ "true"#Unattended-Upgrade::Remove-Unused-Kernel-Packages\ "true"#' /etc/apt/apt.conf.d/50unattended-upgrades
  sudo sed -i 's#^//Unattended-Upgrade::Remove-New-Unused-Dependencies\ "true"#Unattended-Upgrade::Remove-New-Unused-Dependencies\ "true"#' /etc/apt/apt.conf.d/50unattended-upgrades
  sudo sed -i 's#^//Unattended-Upgrade::Automatic-Reboot\ "false"#Unattended-Upgrade::Automatic-Reboot\ "true"#' /etc/apt/apt.conf.d/50unattended-upgrades
  sudo sed -i 's#^//Unattended-Upgrade::Automatic-Reboot-Time\ "02:00"#Unattended-Upgrade::Automatic-Reboot-Time\ "02:17"#' /etc/apt/apt.conf.d/50unattended-upgrades
  echo -e "\e[35m===========================================================\e[00m"
  echo "APT::Periodic::AutocleanInterval \"7\";" | sudo tee -a /etc/apt/apt.conf.d/20auto-upgrades

  # logwatch
  # https://www.howtoforge.com/tutorial/logwatch-installation-on-debian-and-ubuntu/
  # https://help.ubuntu.com/community/Logwatch
  # http://www.stellarcore.net/logwatch/tabs/docs/HOWTO-Customize-LogWatch.html
  sudo apt-get install logwatch -y
  sudo mkdir /var/cache/logwatch
  sudo cp -v /usr/share/logwatch/default.conf/logwatch.conf /etc/logwatch/conf/

  echo -e "\e[35m===========================================================\e[00m"
  echo -e "\e[35mNow, I will edit the /etc/logwatch/conf/logwatch.conf file ...\e[00m"
  echo "	Output = mail"
  echo "	Format = html"
  echo "	MailTo = me@example.com"
  echo "	MailFrom = email@example.com"
  echo "	Detail = High|Med"
  sudo sed -i 's/^Output\ =\ stdout/Output\ =\ mail/' /etc/logwatch/conf/logwatch.conf
  sudo sed -i 's/^Format\ =\ text/Format\ =\ html/' /etc/logwatch/conf/logwatch.conf
  sudo sed -i "s/^MailTo\ =\ root/MailTo\ =\ $root_email/" /etc/logwatch/conf/logwatch.conf
  sudo sed -i "s/^MailFrom\ =\ Logwatch/MailFrom\ =\ $mail_from/" /etc/logwatch/conf/logwatch.conf
  sudo sed -i 's/^Detail\ =\ Low/Detail\ =\ Med/' /etc/logwatch/conf/logwatch.conf
  echo -e "\e[35m===========================================================\e[00m"
}

function furtherHardening() {
  # https://www.digitalocean.com/community/questions/best-practices-for-hardening-new-sever-in-2017
  # https://linux-audit.com/ubuntu-server-hardening-guide-quick-and-secure/
  # https://dennisnotes.com/note/20180627-ubuntu-18.04-server-setup/
  # https://www.ncsc.gov.uk/guidance/eud-security-guidance-ubuntu-1804-lts
  # https://www.ubuntu.com/security
  sudo apt install fail2ban -y
  sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
  echo -e "\e[35m===========================================================\e[00m"
  echo -e "\e[35mNow updating the /etc/fail2ban/jail.local file ...\e[00m"
  sudo sed -i "s/^destemail\ =\ root@localhost/destemail\ =\ $root_email/" /etc/fail2ban/jail.local
  sudo sed -i "s/^sender\ =\ root@<fq-hostname>/sender\ =\ $mail_from/" /etc/fail2ban/jail.local
  echo -e "\e[35menabling sshd ...\e[00m"
  sudo sed -i '/^\[sshd\]/a enabled\ =\ true' /etc/fail2ban/jail.local
  echo -e "\e[35m===========================================================\e[00m"

  # lynix -- https://cisofy.com/lynis/
  sudo apt-key adv --keyserver keyserver.ubuntu.com --recv-keys C80E383C3DE9F082E01391A0366C67DE91CA5D5F
  sudo apt install apt-transport-https -y
  echo 'Acquire::Languages "none";' | sudo tee /etc/apt/apt.conf.d/99disable-translations
  echo "deb https://packages.cisofy.com/community/lynis/deb/ stable main" | sudo tee /etc/apt/sources.list.d/cisofy-lynis.list
  sudo apt update
  sudo apt install lynis -y

  # https://www.theurbanpenguin.com/detecting-rootkits-with-rkhunter-in-ubuntu-18-04/
  sudo apt install -y rkhunter

  sudo lynis audit system
}

function miscellaneousTasks() {

  read -rp 'projects folder: ' PROJECT_DIR
  read -rp 'backup folder: ' BACKUP_DIR
  read -rp 'temporary folder: ' TEMP_DIR

  # let's create some folders
  sudo -i -u "${username}" -H bash -c "mkdir -p /home/${username}/Downloads"
  sudo -i -u "${username}" -H bash -c "mkdir -p /home/${username}/${PROJECT_DIR}"
  sudo -i -u "${username}" -H bash -c "mkdir -p /home/${username}/${BACKUP_DIR}"
  sudo -i -u "${username}" -H bash -c "mkdir -p /home/${username}/${TEMP_DIR}"

  # bring in the custom scripts and geckodriver (for selenium)
  sudo cp -v custom_scripts/create_db /home/"${username}"/bin/
  sudo cp -v custom_scripts/shrinkpdf /home/"${username}"/bin/
  sudo wget https://github.com/mozilla/geckodriver/releases/download/v0.29.1/geckodriver-v0.29.1-linux64.tar.gz -O /home/"${username}"/bin/geckodriver-v0.29.1-linux64.tar.gz
  sudo tar -xvf /home/"${username}"/bin/geckodriver-v0.29.1-linux64.tar.gz -C /home/"${username}"/bin/
  sudo rm -v /home/"${username}"/bin/geckodriver-v0.29.1-linux64.tar.gz

}

function installExtraPackages() {
  sudo apt-get install wkhtmltopdf -y
  # sudo apt install default-jre -y
  sudo apt install openjdk-8-jdk -y

  # pdftk
  sudo snap install pdftk
  # sudo -i -u "${username}" -H bash -c "echo \"\" >> /home/$username/.zshrc"
  # sudo -i -u "${username}" -H bash -c "echo \"\" >> /home/$username/.bashrc"
  # sudo -i -u "${username}" -H bash -c "echo \"# snap\" >> /home/$username/.zshrc"
  # sudo -i -u "${username}" -H bash -c "echo \"# snap\" >> /home/$username/.bashrc"
  # sudo -i -u "${username}" -H bash -c "echo 'export PATH=\"$PATH:/snap/bin\"' >> /home/$username/.zshrc"
  # sudo -i -u "${username}" -H bash -c "echo 'export PATH=\"$PATH:/snap/bin\"' >> /home/$username/.bashrc"

  # ffmpeg, youtube-dl and more
  sudo apt install ffmpeg -y
  sudo -H pip3 install youtube-dl
  sudo apt install libreoffice-common aspell hunspell -y
  sudo apt install inkscape -y
  sudo apt install autoconf automake autotools-dev -y
  sudo apt install pngquant ocrmypdf xvfb rdiff-backup rclone apt-clone firefox -y
  sudo apt install pandoc sqlite3 poppler-utils ncdu libtool -y
  sudo -H pip3 install scour
  
  # install texlive-full
  sudo apt install texlive-full -y  # this may take a while

}

# --------- end addtitional features not in original script --------- #

systemUpdate
main