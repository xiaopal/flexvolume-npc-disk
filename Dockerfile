FROM xiaopal/npc_setup:latest

ADD assets /assets
VOLUME [ "/plugins-exec" ]
CMD ["/usr/bin/ansible-playbook","/assets/installer.yml"]