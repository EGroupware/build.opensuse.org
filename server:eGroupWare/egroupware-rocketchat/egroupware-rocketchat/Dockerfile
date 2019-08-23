FROM rocketchat/rocket.chat:latest

# install sudo and allow rocketchat user to run update-ca-certificates without password
USER root
RUN apt install --y sudo && \
	bash -c "echo 'rocketchat ALL=(ALL) NOPASSWD: /usr/sbin/update-ca-certificates' >> /etc/sudoers"
USER rocketchat

CMD ["bash", "-c", "test -f /usr/local/share/ca-certificates/private-ca.crt && sudo update-ca-certificates; exec node main.js"]
