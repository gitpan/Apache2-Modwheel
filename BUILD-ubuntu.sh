#!/bin/bash

echo "--- Install Modwheel-Apache2"
echo "This will install Apache2 with mod_perl and libapreq enabled"
echo "in /opt/apache2, it requires that you already installed Modwheel in the"
echo "location /opt/modwheel."
echo 
echo "[Press ENTER to continue]"
read

build_dir="./build-modwheel-apache2-$$"
mkdir "$build_dir"
cd "$build_dir"

# ### Install Apache 2.2.4
(
wget http://www.powertech.no/apache/dist/httpd/httpd-2.2.4.tar.gz
tar xvfz httpd-2.2.4.tar.gz
cd httpd-2.2.4
./configure --prefix=/opt/apache2 --with-mpm=prefork
make
sudo make install
)

# ### Install mod_perl 2.0.3
(
wget http://perl.apache.org/dist/mod_perl-2.0-current.tar.gz
tar xvfz mod_perl-2.0-current.tar.gz
cd mod_perl-2.0.3
perl Makefile.PL MP_APXS=/opt/apache2/bin/apxs
make && sudo make install
)

# ### Install Tie::IxHash 1.21 (required by libapreq)
(
wget http://search.cpan.org/CPAN/authors/id/G/GS/GSAR/Tie-IxHash-1.21.tar.gz
tar xvfz Tie-IxHash-1.21.tar.gz
cd Tie-IxHash-1.21
perl Makefile.PL && sudo make install
)

# ### Install Parse::RecDescent 1.94 (required by libapreq)
(
wget http://search.cpan.org/CPAN/authors/id/D/DC/DCONWAY/Parse-RecDescent-1.94.tar.gz
tar xvfz Parse-RecDescent-1.94.tar.gz
cd Parse-RecDescent-1.94
perl Makefile.PL && sudo make install
)

# ### Install ExtUtils::XSBuilder 0.28 (required by libapreq)
(
wget http://search.cpan.org/CPAN/authors/id/G/GR/GRICHTER/ExtUtils-XSBuilder-0.28.tar.gz
tar xvfz ExtUtils-XSBuilder-0.28.tar.gz
cd ExtUtils-XSBuilder-0.28
perl Makefile.PL && sudo make install
)

# ### Install the expat XML-Parser 2.0.0 (required by libapreq)
(
wget http://ovh.dl.sourceforge.net/sourceforge/expat/expat-2.0.0.tar.gz
tar xvfz expat-2.0.0.tar.gz
cd expat-2.0.0
./configure
make && sudo make install
)

# ### Install libconv 1.11 (required by libapreq)
(
wget http://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.11.tar.gz
tar xvfz libiconv-1.11.tar.gz
cd libiconv-1.11
./configure
make && sudo make install
)

# ### Install apreq2
(
wget http://search.cpan.org/CPAN/authors/id/J/JO/JOESUF/libapreq2-2.08.tar.gz
tar xvfz libapreq2-2.08.tar.gz
cd libapreq2-2.08
perl Makefile.PL
make && sudo make install
)

(
wget http://www.0x61736b.net/Modwheel/Modwheel-Apache2-0.01.tar.gz
tar xvfz Modwheel-Apache2-0.01.tar.gz
cd Modwheel-Apache2-0.01
perl Makefile.PL && sudo make install
)

# ### Add LoadModule configuration directives to apache configuration
sudo sh -c 'echo "LoadModule apreq_module /opt/apache2/modules/mod_apreq2.so" >> /opt/apache2/conf/httpd.conf'
sudo sh -c 'echo "LoadModule perl_module  /opt/apache2/modules/mod_perl.so" >> /opt/apache2/conf/httpd.conf'

# ### Add the automaticly generated Modwheel apache config.
sudo sh -c 'cat /opt/modwheel/config/modwheel-apache-example.conf >> /opt/apache2/conf/httpd.conf'

# UBUNTU
sudo killall apache2
sudo chmod 000 /etc/init.d/apache2

sudo /opt/apache2/bin/apachectl start
