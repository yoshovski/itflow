<?php
// Verify the actual image runtime without application credentials or database access.
declare(strict_types=1);

function check(bool $condition, string $message): void
{
    if (!$condition) {
        fwrite(STDERR, "FAIL: $message\n");
        exit(1);
    }
    echo "PASS: $message\n";
}

check(PHP_VERSION_ID >= 80427 && PHP_VERSION_ID < 80500, 'patched PHP 8.4 runtime: ' . PHP_VERSION);
check(!filter_var(ini_get('session.upload_progress.enabled'), FILTER_VALIDATE_BOOLEAN), 'session upload progress disabled');
foreach (['intl', 'mysqli', 'gd', 'zip', 'curl', 'mbstring', 'xml', 'dom', 'fileinfo', 'openssl'] as $extension) {
    check(extension_loaded($extension), "required extension $extension");
}

$locations = openssl_get_cert_locations();
$stores = array_unique(array_filter([
    '/etc/ssl/certs/ca-certificates.crt',
    ini_get('openssl.cafile'),
    ini_get('curl.cainfo'),
    $locations['default_cert_file'],
]));
foreach ($stores as $store) {
    $bundle = file_get_contents($store);
    check($bundle !== false, "CA store readable: $store");
    preg_match_all('/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/s', $bundle, $certificates);
    check(count($certificates[0]) > 0, "CA store populated: $store");
    foreach ($certificates[0] as $pem) {
        $certificate = openssl_x509_parse($pem);
        checkCertificate($certificate, $store);
    }
    echo "PASS: compromised roots absent from $store\n";
}

function checkCertificate(array|false $certificate, string $store): void
{
    if ($certificate === false) {
        throw new RuntimeException("Cannot parse a certificate in $store");
    }
    foreach ((array) ($certificate['subject']['CN'] ?? []) as $name) {
        if (in_array($name, ['emSign ECC Root CA - G3', 'AAA Certificate Services'], true)) {
            throw new RuntimeException("Compromised root still trusted in $store: $name");
        }
    }
}

if (!in_array('--online', $argv, true)) {
    exit(0);
}

$hosts = [
    'example.com' => true,
    'dv-g3b-noct-emudhra.we-have-a-problem.com' => false,
    'dv-g3b-aaa-noct-emudhra.we-have-a-problem.com' => false,
];
foreach ($hosts as $host => $valid) {
    $curl = curl_init("https://$host/");
    curl_setopt_array($curl, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_NOBODY => true,
        CURLOPT_TIMEOUT => 15,
        CURLOPT_CONNECTTIMEOUT => 10,
        CURLOPT_USERAGENT => 'ITFlowCertificateProbe/1.0',
        CURLOPT_SSL_VERIFYPEER => true,
        CURLOPT_SSL_VERIFYHOST => 2,
    ]);
    curl_exec($curl);
    $error = curl_errno($curl);
    $status = curl_getinfo($curl, CURLINFO_RESPONSE_CODE);
    check(
        $valid ? ($error === 0 && $status >= 200 && $status < 400) : $error === CURLE_SSL_CACERT,
        "PHP cURL " . ($valid ? 'valid HTTPS control' : 'certificate rejection') . ": $host (error $error)"
    );

    $warnings = [];
    set_error_handler(static function (int $severity, string $message) use (&$warnings): bool {
        $warnings[] = $message;
        return true;
    });
    try {
        $context = stream_context_create(['ssl' => [
            'verify_peer' => true,
            'verify_peer_name' => true,
            'peer_name' => $host,
        ]]);
        $socket = stream_socket_client("tls://$host:443", $number, $message, 10, STREAM_CLIENT_CONNECT, $context);
    } finally {
        restore_error_handler();
    }
    $accepted = is_resource($socket);
    if ($accepted) {
        fclose($socket);
    }
    $certificateFailure = str_contains(strtolower(implode(' ', $warnings)), 'certificate verify failed');
    check(
        $valid ? $accepted : (!$accepted && $certificateFailure),
        "PHP OpenSSL streams " . ($valid ? 'valid HTTPS control' : 'certificate rejection') . ": $host"
    );
}
