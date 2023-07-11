# Perforce client/server setup script
#
# Copyright (c) 2014 Electric Cloud, Inc.
# All rights reserved
################################

FROM ubuntu

# Update apt sources
RUN apt-get update

# create Perforce user & group
RUN addgroup p4admin
RUN useradd -m -g p4admin perforce

# Install perforce server
ADD http://filehost.perforce.com/perforce/r14.1/bin.linux26x86_64/p4d /usr/local/sbin/

# Install perforce client
ADD http://filehost.perforce.com/perforce/r14.1/bin.linux26x86_64/p4 /usr/local/bin/

RUN chmod +x /usr/local/sbin/p4d /usr/local/bin/p4

RUN mkdir /perforce_depot
RUN chown perforce:p4admin /perforce_depot
RUN mkdir /var/log/perforce
RUN chown perforce:p4admin /var/log/perforce

ENV P4JOURNAL /var/log/perforce/journal
ENV P4LOG /var/log/perforce/p4err
ENV P4PORT 1666
ENV P4ROOT /perforce_depot
ENV P4USER testuser
ENV P4PASSWD testuser
ENV P4CLIENT perforce-test
ENV HOME /home/perforce

# Populate test workspace and perforce database
ADD docker/user.cfg $HOME/user.cfg 
ADD docker/workspace.cfg $HOME/workspace.cfg 
ADD docker/depot/ $HOME/Perforce
RUN chown -R perforce:p4admin $HOME/Perforce

USER perforce
RUN p4d -d; sleep 10; p4 user -i < $HOME/user.cfg; p4 client -i < $HOME/workspace.cfg; find $HOME/Perforce -type f -print | p4 -x - add; p4 submit -d "Initial changelist" 

# Expose port
EXPOSE 1666
