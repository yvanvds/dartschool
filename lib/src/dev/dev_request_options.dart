class DevRequestOptions {
  final Map<String, String>? headers;
  final Map<String, dynamic>? query;
  final Object? data;
  final Map<String, String>? formData;
  final String? contentType;
  final bool isJson;

  const DevRequestOptions({
    this.headers,
    this.query,
    this.data,
    this.formData,
    this.contentType,
    this.isJson = false,
  });
}
