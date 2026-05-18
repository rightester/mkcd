mkdir @args
if ($?) {
  Set-Location $args[-1]
}
