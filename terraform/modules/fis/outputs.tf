output "experiment_template_id" {
  value       = aws_fis_experiment_template.spot_killer.id
  description = "AWS FIS experiment template ID — pass to `scripts/kill-spot.sh` or `aws fis start-experiment` to trigger a real spot interruption."
}
