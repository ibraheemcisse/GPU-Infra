output "control_plane_public_ip" {
  value = aws_eip.control_plane.public_ip
}

output "control_plane_private_ip" {
  value = aws_instance.control_plane.private_ip
}

output "gpu_worker_public_ip" {
  value = aws_eip.gpu_worker.public_ip
}

output "gpu_worker_private_ip" {
  value = aws_instance.gpu_worker.private_ip
}

output "ssh_control_plane" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_eip.control_plane.public_ip}"
}

output "ssh_gpu_worker" {
  value = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_eip.gpu_worker.public_ip}"
}
