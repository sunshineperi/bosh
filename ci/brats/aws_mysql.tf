variable "rds_mysql_username" {}
variable "rds_mysql_password" {}
variable "rds_mysql_databasename" {}

resource "aws_db_parameter_group" "default" {
  name   = "brats-mysql"
  family = "mysql5.7"

  parameter {
    name = "log_bin_trust_function_creators"
    value = 1
  }

  parameter {
    name  = "character_set_server"
    value = "utf8"
  }

  parameter {
    name  = "character_set_client"
    value = "utf8"
  }
}

resource "aws_db_instance" "mysql" {
  allocated_storage      = 10
  storage_type           = "gp2"
  engine                 = "mysql"
  engine_version         = "5.7"
  instance_class         = "db.t2.micro"
  skip_final_snapshot    = true
  name                   = "${var.rds_mysql_databasename}"
  username               = "${var.rds_mysql_username}"
  password               = "${var.rds_mysql_password}"
  parameter_group_name   = "brats-mysql"
  vpc_security_group_ids = ["${aws_security_group.allow-db-access.id}"]
  db_subnet_group_name   = "${aws_db_subnet_group.default.id}"
  publicly_accessible    = true
}

output "aws_mysql_endpoint" {
  value = "${aws_db_instance.mysql.endpoint}"
}

