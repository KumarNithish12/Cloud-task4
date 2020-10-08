provider "aws" {
  region  = "ap-south-1"
  profile = "terrakey"
}

resource "aws_vpc" "vpcmain" {
  cidr_block           = "192.168.0.0/16"
  instance_tenancy     = "default"
  enable_dns_hostnames = "true"

  tags = {
    Name = "tf_nkvpc"
  }
}

resource "aws_subnet" "subnet1a_public" {
  vpc_id                  = "${aws_vpc.vpcmain.id}"
  cidr_block              = "192.168.0.0/24"
  availability_zone       = "ap-south-1a"
  map_public_ip_on_launch = "true"

  tags = {
    Name = "nksubnet-1a-public"
  }
}

resource "aws_subnet" "subnet1b_private" {
  vpc_id                  = "${aws_vpc.vpcmain.id}"
  cidr_block              = "192.168.1.0/24"
  availability_zone       = "ap-south-1b"
  map_public_ip_on_launch = false

  tags = {
    Name = "nksubnet-1b-private"
  }
}

resource "aws_internet_gateway" "myingw" {
  vpc_id = "${aws_vpc.vpcmain.id}"

  tags = {
    Name = "nk_internet_gw"
  }
}

resource "aws_route_table" "routingingw" {
  depends_on = [
    aws_internet_gateway.myingw
  ]

  vpc_id = "${aws_vpc.vpcmain.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.myingw.id}"
  }
  tags = {
    Name = "rtinternetgw"
  }
}

resource "aws_route_table_association" "sb-ass1" {
  depends_on = [
    aws_route_table.routingingw
  ]

  subnet_id      = "${aws_subnet.subnet1a_public.id}"
  route_table_id = "${aws_route_table.routingingw.id}"
}

resource "aws_eip" "awseip" {
  vpc = true
  tags = {
    Name = "myeip"
  }
}

resource "aws_nat_gateway" "mynatgw" {
  depends_on = [
    aws_eip.awseip
  ]

  allocation_id = "${aws_eip.awseip.id}"
  subnet_id     = "${aws_subnet.subnet1a_public.id}"

  tags = {
    Name = "gw NAT"
  }
}

resource "aws_route_table" "routingnatgw" {
  depends_on = [
    aws_nat_gateway.mynatgw
  ]

  vpc_id = "${aws_vpc.vpcmain.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_nat_gateway.mynatgw.id}"
  }
  tags = {
    Name = "rtnatgw"
  }
}

resource "aws_route_table_association" "sb-ass2" {
  depends_on = [
    aws_route_table.routingnatgw
  ]

  subnet_id      = "${aws_subnet.subnet1b_private.id}"
  route_table_id = "${aws_route_table.routingnatgw.id}"
}

resource "aws_security_group" "wpsecurity" {
  depends_on = [
    aws_route_table_association.sb-ass1
  ]

  name        = "wp_security"
  description = "Allow SSH, ICMP, HTTP for WP "
  vpc_id      = "${aws_vpc.vpcmain.id}"


  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "ICMP"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "wp_sg"
  }
}

resource "aws_security_group" "mysqlsecurity" {
  depends_on = [
    aws_route_table_association.sb-ass2
  ]

  name        = "mysql_security"
  description = "Allow MySQL(3306) and wp_security for MySQL "
  vpc_id      = "${aws_vpc.vpcmain.id}"

  ingress {
    description     = "MYSQL"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.wpsecurity.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "mysql_sg"
  }
}

resource "aws_instance" "wordpress" {
  depends_on = [
    aws_security_group.wpsecurity
  ]

  ami                         = "ami-0e306788ff2473ccb"
  instance_type               = "t2.micro"
  associate_public_ip_address = true
  subnet_id                   = "${aws_subnet.subnet1a_public.id}"
  key_name                    = "mykey11"
  availability_zone           = "ap-south-1a"
  vpc_security_group_ids      = [aws_security_group.wpsecurity.id]

  tags = {
    Name = "wp_os"
  }
}

resource "aws_instance" "mysql" {
  depends_on = [
    aws_instance.wordpress
  ]

  ami                    = "ami-0e306788ff2473ccb"
  instance_type          = "t2.micro"
  subnet_id              = "${aws_subnet.subnet1b_private.id}"
  availability_zone      = "ap-south-1b"
  vpc_security_group_ids = [aws_security_group.mysqlsecurity.id]

  user_data = <<END
  #!/bin/bash
  sudo yum install mariadb-server mysql -y
  sudo systemctl enable mariadb.service
  sudo systemctl start mariadb.service
  mysql -u root <<EOF
  create user 'kumar'@'${aws_instance.wordpress.private_ip}' identified by 'rootpass';
  create database mywpdb;
  grant all privileges on mywpdb.* to 'kumar'@'${aws_instance.wordpress.private_ip}';
  exit
  EOF
  END

  tags = {
    Name = "sql_os"
  }
}

resource "null_resource" "login-to-wp" {
  depends_on = [
    aws_instance.mysql
  ]

  connection {
    type        = "ssh"
    user        = "ec2-user"
    private_key = file("/home/nithish/Downloads/mykey11.pem")
    host        = aws_instance.wordpress.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo su <<END",
      "yum install docker httpd -y",
      "systemctl enable docker",
      "systemctl start docker",
      "docker pull wordpress:5.1.1-php7.3-apache",
      "sleep 20",
      "docker run -dit  -e WORDPRESS_DB_HOST=${aws_instance.mysql.private_ip} -e WORDPRESS_DB_USER=kumar -e WORDPRESS_DB_PASSWORD=rootpass -e WORDPRESS_DB_NAME=mywpdb -p 80:80 wordpress:5.1.1-php7.3-apache",
      "END",
    ]
  }
}

resource "null_resource" "openwpsite" {
  depends_on = [
    null_resource.login-to-wp
  ]
  provisioner "local-exec" {
    command = "google-chrome  http://${aws_instance.wordpress.public_ip} &"
  }
}
