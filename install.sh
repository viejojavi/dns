#!/bin/sh
#agregar usuario
useradd -m ticcol -s /bin/bash && echo "ticcol:T1CC0L2O!7" | chpasswd
usermod -aG sudo ticcol
sleep 5

#Cabecera
chmod -x /etc/update-motd.d/*
cd /etc/update-motd.d
rm 00-header
wget https://raw.githubusercontent.com/viejojavi/header/main/00-header
chmod +x 00-header
echo "Header Listo"
sleep 5

#Instala Bind
apt-get update -y
apt-get upgrade -y
apt install bind9 bind9-utils -y
sleep 5

#Configurar DNS Recursivo
cd /etc/bind
rm named.conf.options
wget https://raw.githubusercontent.com/viejojavi/dns/main/named.conf.options
sleep 5

#Colocar bind9 como resolver
rm /etc/resolv.conf
cd /etc/
wget https://raw.githubusercontent.com/viejojavi/dns/refs/heads/main/resolv.conf
sleep 5

#Verificar configuracion
named-checkconf
echo "Configurarcion Correcta"
sleep 5

#Reiniciar servidor DNS
systemctl restart bind9
echo "Servidor operativo"
sleep 5

systemctl status bind9
