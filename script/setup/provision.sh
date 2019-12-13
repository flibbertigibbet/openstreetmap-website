#!/usr/bin/env bash

# abort on error
set -e

# set locale to UTF-8 compatible
sudo locale-gen en_US.utf8
sudo update-locale LANG=en_US.utf8 LC_ALL=en_US.utf8
export LANG=en_US.utf8
export LC_ALL=en_US.utf8

# check if yarn is installed
if ! dpkg -s yarn; then
    echo 'install packages'
    # add repository for yarn
    # https://yarnpkg.com/lang/en/docs/install/#debian-stable
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
    echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list

    # make sure we have up-to-date packages
    sudo apt-get update

    # upgrade all packages
    sudo apt-get upgrade -y

    # install packages as explained in INSTALL.md
    sudo apt-get install -y ruby2.5 libruby2.5 ruby2.5-dev \
                            libmagickwand-dev libxml2-dev libxslt1-dev fontconfig nodejs \
                            apache2 apache2-dev build-essential git-core \
                            postgresql postgresql-contrib libpq-dev \
                            libsasl2-dev imagemagick libffi-dev libgd-dev libarchive-dev libbz2-dev \
                            openjdk-11-jdk openjdk-11-doc osmosis postgis yarn

    # install a phantomjs version that will work headlessly
    pushd /tmp
    wget https://bitbucket.org/ariya/phantomjs/downloads/phantomjs-2.1.1-linux-x86_64.tar.bz2
    tar jxvf phantomjs-2.1.1-linux-x86_64.tar.bz2
    sudo cp phantomjs-2.1.1-linux-x86_64/bin/phantomjs /usr/bin/
    popd
fi

# Run SQL
echo "current directory: $(pwd)"
echo 'drop and recreate databases and users'
sudo -u postgres psql -f script/setup/recreate_databases.sql

echo 'add database extensions'
sudo -u postgres psql -f script/setup/add_extensions.sql openstreetmap
sudo -u postgres psql -f script/setup/add_extensions.sql osm_test

## install the bundle necessary for openstreetmap-website
gem2.5 install rake
gem2.5 install --version "~> 1.16.2" bundler
# do bundle install as a convenience
bundle install --retry=10 --jobs=2

# Create the database tables for OSM an migrate to the specific APIDB schema version
# that is the last APIDB version used by osmosis:
# https://github.com/openstreetmap/osmosis/blob/2219470cef1f73f5d1319c57149c84b398e767ce/osmosis-apidb/src/main/java/org/openstreetmap/osmosis/apidb/v0_6/ApidbVersionConstants.java
echo 'apply migrations to osmosis version'
bundle exec rake db:migrate VERSION=20130328184137

# Workaround for attempted user imports failing with:
# ERROR: duplicate key value violates unique constraint "users_display_name_idx"
echo 'drop user display name index as a workaround'
sudo -u postgres psql -c "drop index users_display_name_idx" openstreetmap

# Run osmosis import for whatever OSM files are in the `data` directory
if [ -f data/*.osm ]; then
    echo 'import data directory OSM contents with osmosis'
    osmosis --read-xml data/*.osm --write-apidb \
        database="openstreetmap" user="openstreetmap" password="openstreetmap"
fi
if [ -f data/*.pbf ]; then
    echo 'import data directory PBF contents with osmosis'
    osmosis --read-pbf data/*.pbf --write-apidb \
        database="openstreetmap" user="openstreetmap" password="openstreetmap"
fi

# Add back index removed for import.
# Should be safe, if uniqueness violations were from users changing their display name,
# then changing it back.
echo 'add back display name index'
sudo -u postgres psql -c "CREATE UNIQUE INDEX users_display_name_idx ON users (display_name)" openstreetmap


# install PostgreSQL functions
echo 'install functions'
sudo -u postgres psql -d openstreetmap -f db/functions/functions.sql

# set up sample configs
if [ ! -f config/database.yml ]; then
    cp config/example.database.yml config/database.yml
fi
if [ ! -f config/storage.yml ]; then
    cp config/example.storage.yml config/storage.yml
fi

touch config/settings.local.yml

# migrate the database from the osmosis version to the latest version
echo 'apply remaining migrations'
bundle exec rake db:migrate

echo 'export i8ln'
bundle exec rake i18n:js:export
echo 'install npm packages'
bundle exec rake yarn:install

echo 'all done'
