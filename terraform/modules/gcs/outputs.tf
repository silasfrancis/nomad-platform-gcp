output "bucket_names" {
  description = "Map of bucket key to bucket name for all buckets created by bootstrap."
  value = {
    for key, bucket in google_storage_bucket.buckets :
    key => bucket.name
  }
}

output "bucket_urls" {
  description = "Map of bucket key to bucket url for all buckets created by bootstrap."
  value = {
    for key, bucket in google_storage_bucket.buckets :
    key => bucket.url
  }
}
