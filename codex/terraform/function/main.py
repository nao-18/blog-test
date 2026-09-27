import functions_framework


@functions_framework.http
def hello_http(request):
    return ("ok\n", 200, {"Content-Type": "text/plain"})
